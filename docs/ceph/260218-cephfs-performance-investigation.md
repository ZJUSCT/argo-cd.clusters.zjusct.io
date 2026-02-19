# CephFS Performance Investigation Roadmap

**Context:** CephFS small-file performance is severely degraded — `rm -rf node_modules` takes >10 minutes.
**Cluster:** Rook-Ceph v1.19.1, Ceph 19.2.3 (Squid), 27 OSDs across 3 nodes, 2 active MDS + 2 standby-replay, 49 connected clients.

---

## Current State: Diagnosis from Live Data

From `ceph tell mds.cephfs-b perf dump` on 2026-02-18, the following latencies are confirmed:

| Operation | Avg Latency | Count | Assessment |
|---|---|---|---|
| journal write (`jlat`) | **31.5 ms** | 3M | Critical bottleneck |
| `rename` | **32.3 ms** | 173K | Journal-bound |
| `setattr` | **18.1 ms** | 575K | Journal-bound |
| `rmdir` | **12.2 ms** | 78K | Journal-bound |
| `readdir` | **3.7 ms** | 9.96M | High; causes cascading round-trips |
| `getattr` | **6.7 ms** | 664K | High |
| `open` | **2.2 ms** | 2.29M | Acceptable |
| `unlink` | **0.29 ms** | 695K | Fine |
| `mkdir` | **0.65 ms** | 156K | Fine |

**Root cause hypothesis:** The MDS metadata journal (on the `cephfs-metadata` pool on NVMe OSDs) has 31.5ms write latency. This serializes all mutating MDS operations. For `rm -rf node_modules`, the client must readdir every directory, unlink every file, and rmdir each directory — with each level requiring synchronous journal commits.

**Secondary factor:** `readdir` at 3.7ms means a directory with 1000 entries requires multiple 3–4ms round trips. `node_modules` typically has tens of thousands of directories, making this multiplicative.

**Current metadata pool IO:** 204 KiB/s rd, 232 KiB/s wr, 5 op/s rd, 8 op/s wr — very low, ruling out throughput saturation.

---

## Two Parallel Investigation Tracks

```
Track A: Metrics (Prometheus/Grafana)    Track B: Traces & Profiles
already collecting → extend queries      not yet set up → deploy now
```

---

## Track A: Metrics — Extend Existing Prometheus Coverage

### A1. MDS-Specific Grafana Dashboard

The current Grafana setup has Ceph Cluster (ID 2842), Ceph OSD (ID 5336), and Ceph Pools (ID 5342). These do not cover MDS in depth. Add:

**Import the MDS dashboard:**
```
Grafana → Dashboards → Import → ID: 14842
(Ceph MDS dashboard from grafana.com)
```

Alternatively, build a custom dashboard with these critical PromQL queries:

```promql
# MDS journal write latency (most important metric)
rate(ceph_mds_log_jlat_sum[5m]) / rate(ceph_mds_log_jlat_avgcount[5m])

# Per-operation latency
rate(ceph_mds_server_handle_client_request[5m])

# MDS cache hit/miss ratio
ceph_mds_inodes / (ceph_mds_inodes + ceph_mds_inodes_expired)

# Metadata pool OSD write latency (commit latency)
ceph_osd_op_w_latency_sum{pool="cephfs-metadata"} /
ceph_osd_op_w_latency_avgcount{pool="cephfs-metadata"}

# Active MDS request queue depth
ceph_mds_request

# MDS cap revocations in flight (indicates client pressure)
ceph_mds_ceph_cap_op_revoke

# readdir operation rate
rate(ceph_mds_server_dispatch_client_request[5m])
```

### A2. Key Metrics to Watch During a Test Workload

Run `rm -rf /mnt/cephfs/test_node_modules` and simultaneously monitor:

```bash
# Watch MDS operation latency live
watch -n2 "kubectl -n rook-ceph exec deploy/rook-ceph-tools -- \
  ceph tell mds.cephfs-b perf dump --format json 2>/dev/null | \
  python3 -c \"
import sys, json
lines = sys.stdin.readlines()
for i, l in enumerate(lines):
    if l.strip().startswith('{'):
        d = json.loads(''.join(lines[i:]))['mds_server']
        for op in ['readdir','unlink','rmdir','rename']:
            k = f'req_{op}_latency'
            if k in d and d[k]['avgcount'] > 0:
                print(f'{op}: {d[k][\\\"avgtime\\\"]*1000:.2f}ms ({d[k][\\\"avgcount\\\"]} ops)')
        break
\""
```

```bash
# Watch MDS journal latency live
watch -n2 "kubectl -n rook-ceph exec deploy/rook-ceph-tools -- \
  ceph tell mds.cephfs-b perf dump --format json 2>/dev/null | \
  python3 -c \"
import sys, json
lines = sys.stdin.readlines()
for i, l in enumerate(lines):
    if l.strip().startswith('{'):
        d = json.loads(''.join(lines[i:]))['mds_log']
        jl = d['jlat']
        print(f'journal latency: {jl[\\\"avgtime\\\"]*1000:.2f}ms avg ({jl[\\\"avgcount\\\"]} writes)')
        break
\""
```

### A3. OSD Latency Correlation

The metadata pool is on NVMe devices. Check if the OSD WAL/DB is saturated:

```bash
# Per-OSD commit and apply latency for metadata OSDs
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- \
  ceph osd perf 2>&1 | sort -k3 -rn | head -20

# Identify which OSDs hold the metadata pool PGs
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- \
  ceph osd map cephfs-metadata <any_oid> 2>&1

# Check OSD utilization on metadata pool
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- \
  ceph pg ls-by-pool cephfs-metadata 2>&1 | head -30
```

### A4. Prometheus Alerting Rules to Add

Add to `production/rook-ceph/resources/` a PrometheusRule for MDS-specific alerts:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: cephfs-mds-performance
  namespace: rook-ceph
spec:
  groups:
  - name: cephfs.mds.performance
    rules:
    - alert: CephMDSJournalLatencyHigh
      expr: |
        rate(ceph_mds_log_jlat_sum[5m]) / rate(ceph_mds_log_jlat_avgcount[5m]) > 0.020
      for: 5m
      labels:
        severity: warning
      annotations:
        summary: "MDS journal write latency > 20ms (current: {{ $value | humanizeDuration }})"

    - alert: CephMDSReaddirLatencyHigh
      expr: |
        rate(ceph_mds_server_req_readdir_latency_sum[5m]) /
        rate(ceph_mds_server_req_readdir_latency_avgcount[5m]) > 0.005
      for: 5m
      labels:
        severity: warning
      annotations:
        summary: "MDS readdir latency > 5ms"

    - alert: CephMDSCacheNearFull
      expr: |
        ceph_mds_mem_rss / (2 * 1024 * 1024 * 1024) > 0.85
      for: 5m
      labels:
        severity: warning
      annotations:
        summary: "MDS cache memory > 85% of 2GB limit"
```

### A5. Enable Additional Ceph Exporter Metrics

The current ceph exporter has `perfCountersPrioLimit` set. Lower it to expose more detailed counters:

```yaml
# In rook-ceph-cluster values, under cephClusterSpec.monitoring.exporter:
exporter:
  perfCountersPrioLimit: 5   # lower = more counters (default is higher)
  statsPeriodSeconds: 5      # scrape every 5s during investigation
```

---

## Track B: Traces and Profiles

### B1. Ceph Built-in Jaeger Tracing (OSD and RGW only)

**Important limitation:** As of Ceph 19.2.3, `jaeger_tracing_enable` only supports `osd` and `rgw` — not `mds`. This means Jaeger will not give you MDS request traces. However, enabling it for OSDs is still valuable because it reveals how long the metadata pool RADOS operations take end-to-end, which is what the MDS journal is waiting for.

#### Deploy Jaeger

Since this is Rook (not cephadm), deploy Jaeger as Kubernetes resources. Use the all-in-one image for investigation (not production):

```yaml
# jaeger-all-in-one.yaml  (place in production/rook-ceph/resources/)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: jaeger
  namespace: rook-ceph
spec:
  replicas: 1
  selector:
    matchLabels:
      app: jaeger
  template:
    metadata:
      labels:
        app: jaeger
    spec:
      containers:
      - name: jaeger
        image: jaegertracing/all-in-one:1.54
        ports:
        - containerPort: 6831   # UDP Thrift compact (agent port)
          protocol: UDP
        - containerPort: 6832   # UDP Thrift binary
          protocol: UDP
        - containerPort: 16686  # Query UI
        - containerPort: 14268  # HTTP collector
        env:
        - name: COLLECTOR_ZIPKIN_HOST_PORT
          value: ":9411"
        resources:
          requests:
            memory: 512Mi
            cpu: 100m
          limits:
            memory: 2Gi
---
apiVersion: v1
kind: Service
metadata:
  name: jaeger
  namespace: rook-ceph
spec:
  selector:
    app: jaeger
  ports:
  - name: agent-compact
    port: 6831
    protocol: UDP
  - name: agent-binary
    port: 6832
    protocol: UDP
  - name: collector-http
    port: 14268
  - name: query
    port: 16686
```

#### Enable Jaeger Tracing in Ceph OSDs

Once Jaeger is deployed, get its ClusterIP:

```bash
JAEGER_IP=$(kubectl -n rook-ceph get svc jaeger -o jsonpath='{.spec.clusterIP}')

# Enable Jaeger tracing on all OSDs
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- \
  ceph config set osd jaeger_tracing_enable true

kubectl -n rook-ceph exec deploy/rook-ceph-tools -- \
  ceph config set osd jaeger_agent_host ${JAEGER_IP}

kubectl -n rook-ceph exec deploy/rook-ceph-tools -- \
  ceph config set osd jaeger_agent_port 6831
```

OSDs will begin emitting traces for RADOS read/write operations. Open the Jaeger UI:

```bash
kubectl -n rook-ceph port-forward svc/jaeger 16686:16686
# Then open http://localhost:16686
```

Filter for service `osd` and look at traces tagged with the `cephfs-metadata` pool PG IDs during a metadata-heavy workload to see end-to-end write latency through the OSD.

#### Expose Jaeger UI via Ingress (optional for persistent access)

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: jaeger
  namespace: rook-ceph
spec:
  rules:
  - host: jaeger.clusters.zjusct.io
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: jaeger
            port:
              number: 16686
```

### B2. MDS Tracing — Built-in Op Tracing (No Jaeger Required)

Since Jaeger does not support MDS, use Ceph's built-in MDS operation dump. This gives synchronous snapshots of in-flight and recently completed operations:

```bash
# Dump all in-flight MDS client requests (snapshot)
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- \
  ceph tell mds.cephfs-b dump_ops_in_flight --format json-pretty 2>&1

# List blocked ops (waiting > threshold)
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- \
  ceph tell mds.cephfs-b dump_blocked_ops --format json-pretty 2>&1

# Show recent completed requests with latency breakdown
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- \
  ceph tell mds.cephfs-b dump_historic_ops --format json-pretty 2>&1 | \
  python3 -c "
import sys, json
data = json.load(sys.stdin)
ops = data.get('ops', [])
# Sort by duration descending
ops.sort(key=lambda x: x.get('duration', 0), reverse=True)
for op in ops[:20]:
    print(f\"{op.get('duration',0)*1000:.1f}ms  {op.get('description','')}\")
"

# Increase the historic ops buffer for better sampling
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- \
  ceph tell mds.cephfs-b config set mds_op_history_size 200

kubectl -n rook-ceph exec deploy/rook-ceph-tools -- \
  ceph tell mds.cephfs-b config set mds_op_history_duration 600
```

The `dump_historic_ops` output includes per-operation event timelines: `initiated → acquired_locks → started → commit → applied → completed`. This is the closest you get to distributed tracing for MDS without LTTng.

### B3. MDS Debug Logging — Targeted Subsystem Logging

For investigating specific slow operation types, enable targeted debug logging at runtime without restarting:

```bash
# Enable MDS server-side request logging (verbose but targeted)
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- \
  ceph tell mds.cephfs-b config set debug_mds 5

# Enable MDS journal logging
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- \
  ceph tell mds.cephfs-b config set debug_journal 5

# Enable MDS objecter (RADOS client inside MDS) logging
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- \
  ceph tell mds.cephfs-b config set debug_objecter 5
```

Then tail the MDS log:
```bash
kubectl -n rook-ceph logs -f deploy/rook-ceph-mds-cephfs-b --since=1m | \
  grep -E 'slow|latency|blocked|journal|RADOS'
```

**Reset after investigation** (debug logging is heavy):
```bash
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- \
  ceph tell mds.cephfs-b config set debug_mds 1
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- \
  ceph tell mds.cephfs-b config set debug_journal 1
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- \
  ceph tell mds.cephfs-b config set debug_objecter 0
```

### B4. OSD-Side Profiling for Metadata Pool

Since the journal latency (31.5ms) dominates, profile the OSDs serving the metadata pool:

```bash
# Identify metadata pool OSDs
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- \
  ceph osd map cephfs-metadata 0000000000000001.00000000 2>&1

# Check per-OSD latency (apply = journal write latency)
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- \
  ceph osd perf --format json 2>&1 | python3 -c "
import sys, json
data = json.load(sys.stdin)
osds = data.get('osd_perf_infos', [])
osds.sort(key=lambda x: x['perf_stats']['apply_latency_ms'], reverse=True)
print('OSD  commit_ms  apply_ms')
for o in osds[:15]:
    s = o['perf_stats']
    print(f\"{o['id']:3d}  {s['commit_latency_ms']:8.1f}  {s['apply_latency_ms']:7.1f}\")
"

# Watch OSD latency during a workload
watch -n3 "kubectl -n rook-ceph exec deploy/rook-ceph-tools -- \
  ceph osd perf --format json 2>/dev/null | python3 -c \"
import sys, json
data = json.load(sys.stdin)
osds = data['osd_perf_infos']
osds.sort(key=lambda x: x['perf_stats']['apply_latency_ms'], reverse=True)
print('OSD  commit_ms  apply_ms')
for o in osds[:10]:
    s = o['perf_stats']
    print(f\\\"{o['id']:3d}  {s['commit_latency_ms']:8.1f}  {s['apply_latency_ms']:7.1f}\\\")
\""
```

### B5. CPU Profiling of MDS (If Latency is CPU-Bound)

If `dump_historic_ops` shows long `acquired_locks → started` intervals, the MDS may be CPU-bound. Profile with perf inside the MDS pod:

```bash
# Get MDS pod name
MDS_POD=$(kubectl -n rook-ceph get pod -l app=rook-ceph-mds,mds=cephfs-b -o name)

# Exec into the pod
kubectl -n rook-ceph exec -it ${MDS_POD} -- bash

# Inside the pod: find ceph-mds PID and profile for 30 seconds
MDS_PID=$(pgrep -f ceph-mds)
dnf install -y perf 2>/dev/null || apt-get install -y linux-perf 2>/dev/null
perf record -e cycles --call-graph dwarf -p ${MDS_PID} -- sleep 30
perf report --stdio 2>&1 | head -80
```

This requires `ROOK_HOSTPATH_REQUIRES_PRIVILEGED=true` in the operator deployment if not already set.

---

## Investigation Procedure: Reproducing the Bottleneck Controlled

Run this on a client node that has CephFS mounted to generate a controlled workload while both tracks monitor simultaneously:

```bash
# Step 1: Create test tree (simulate node_modules)
mkdir -p /mnt/cephfs/perf-test/node_modules
python3 -c "
import os, pathlib
base = pathlib.Path('/mnt/cephfs/perf-test/node_modules')
for i in range(200):         # 200 packages
    pkg = base / f'pkg-{i}'
    pkg.mkdir(exist_ok=True)
    for j in range(50):      # 50 files each
        (pkg / f'file-{j}.js').write_text('x' * 100)
    for j in range(10):      # 10 subdirs each
        sub = pkg / f'sub-{j}'
        sub.mkdir(exist_ok=True)
        for k in range(20):  # 20 files in each subdir
            (sub / f'file-{k}.js').write_text('x' * 100)
print('Created ~120000 files in 2200 directories')
"

# Step 2: While deleting, monitor in separate terminals

# Terminal 1: Watch MDS latencies
watch -n1 "kubectl -n rook-ceph exec deploy/rook-ceph-tools -- \
  ceph tell mds.cephfs-b perf dump --format json 2>/dev/null | \
  python3 -c \"...\" "  # use the watch command from A2

# Terminal 2: Watch OSD latencies
watch -n1 "kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd perf"

# Terminal 3: Sample historic ops every 10 seconds
while true; do
  kubectl -n rook-ceph exec deploy/rook-ceph-tools -- \
    ceph tell mds.cephfs-b dump_historic_ops --format json-pretty 2>&1 | \
    python3 -c "..." >> /tmp/mds-ops-$(date +%s).json
  sleep 10
done

# Step 3: Time the deletion
time rm -rf /mnt/cephfs/perf-test/node_modules
```

---

## Optimization Candidates (Prioritized by Evidence)

Based on the 31.5ms journal latency, these are the most likely impactful changes. **Do not apply without first confirming with metrics.**

### O1. MDS Cache Memory (High Priority)

Current: 2GB per MDS daemon. With 660K inodes loaded and `inodes_expired` at 84.9M (evictions), the cache is being thrashed. The 49 clients sharing 660K inodes means each client averages ~13K cached inodes — likely insufficient for deep directory trees.

```bash
# Verify current setting
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- \
  ceph config get mds mds_cache_memory_limit

# Increase to 4GB for active MDSs (MDS pods have 4Gi memory limit in values)
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- \
  ceph config set mds mds_cache_memory_limit 3758096384  # 3.5GB, leaving headroom
```

### O2. Metadata Pool WAL/DB Check (High Priority)

31ms journal latency on NVMe should not happen. Verify the NVMe WAL is not shared with data:

```bash
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- \
  ceph osd metadata 0 2>&1 | grep -E 'bluefs|devices|rotational|db_|wal_'
```

If `bluestore_db_separate_device` is empty, the WAL/DB is on the same device as data, which serializes writes.

### O3. Readdir Latency — MDS Dirfrag Caching

High `readdir` latency (3.7ms) with 9.96M ops suggests many `dir_fetch` operations from RADOS. Check:

```bash
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- \
  ceph tell mds.cephfs-b perf dump --format json 2>/dev/null | \
  python3 -c "
import sys, json
lines = sys.stdin.readlines()
for i, l in enumerate(lines):
    if l.strip().startswith('{'):
        d = json.loads(''.join(lines[i:]))['mds']
        print(f'dir_fetch_complete: {d[\"dir_fetch_complete\"]}')
        print(f'traverse_dir_fetch: {d[\"traverse_dir_fetch\"]}')
        print(f'inodes: {d[\"inodes\"]}')
        print(f'inodes_expired: {d[\"inodes_expired\"]}')
        break
"
```

If `traverse_dir_fetch` is high relative to `traverse_hit`, directories are being re-fetched from RADOS repeatedly. This directly points to cache churn → increase `mds_cache_memory_limit`.

### O4. Client-Side: Use `find` + `xargs` for Parallel Deletion

The client-side `rm -rf` is inherently sequential per directory level. A parallel approach reduces the round-trip amplification:

```bash
# Parallel deletion (saturates MDS more evenly, often much faster)
find /mnt/cephfs/node_modules -mindepth 1 -maxdepth 1 -type d | \
  xargs -P8 -I{} rm -rf {}
```

### O5. Tune MDS Max Caps per Client

If many clients each hold many caps, the revocation waterfall when a new client needs caps stalls all operations:

```bash
# Check current cap distribution
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- \
  ceph tell mds.cephfs-b session ls --format json 2>&1 | \
  python3 -c "
import sys, json
sessions = json.load(sys.stdin)
for s in sorted(sessions, key=lambda x: x.get('num_caps',0), reverse=True)[:10]:
    print(f\"client {s['id']:8}: caps={s.get('num_caps',0)}, ip={s.get('client_ip','?')}\")
"

# If any single client holds excessive caps, tune
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- \
  ceph config set mds mds_max_caps_per_client 16384  # default is 32768
```

---

## Monitoring Schedule

| Timeline | Action |
|---|---|
| Day 1 | Import MDS Grafana dashboard, run baseline perf dump, identify top-latency operations |
| Day 1 | Deploy Jaeger all-in-one, enable OSD Jaeger tracing |
| Day 2 | Run controlled deletion test with live monitoring on both tracks |
| Day 2 | Collect `dump_historic_ops` during test, analyze event timelines |
| Day 3 | Correlate OSD traces with MDS journal latency — confirm if NVMe write latency is the bottleneck |
| Day 3 | Check MDS cache hit rates; decide on `mds_cache_memory_limit` increase |
| Day 4 | Apply highest-confidence tuning (cache, potentially WAL config), re-run controlled test |
| Day 5 | Compare before/after metrics; if journal latency unchanged, escalate to OSD perf profiling |
| Ongoing | Keep Jaeger and MDS dashboard running; alert on `jlat > 20ms` |

---

## Key Files and References

| Resource | Location |
|---|---|
| Cluster values | `production/rook-ceph/values/rook-ceph-cluster-v1.19.1.yaml` |
| ServiceMonitor (mgr) | `production/rook-ceph/resources/rook-ceph-mgr-monitor.yaml` |
| PrometheusRules | `production/rook-ceph/charts/rook-ceph-cluster-v1.19.1/.../prometheusrules.yaml` |
| Ceph tracing docs | `tmp/ceph/doc/cephadm/services/tracing.rst` |
| Rook perf profiling | `tmp/rook/Documentation/Troubleshooting/performance-profiling.md` |
| Rook monitoring docs | `tmp/rook/Documentation/Storage-Configuration/Monitoring/ceph-monitoring.md` |

**Note on Ceph MDS tracing:** Ceph 19.2.3 `jaeger_tracing_enable` only applies to `osd` and `rgw` services. MDS tracing via OpenTelemetry/Jaeger is not yet upstream. The `dump_historic_ops` + subsystem debug logging approach (Track B2/B3) is the MDS equivalent for this cluster.
