# PostgreSQL on Ceph RBD Performance Investigation

Date: 2026-06-11

## Background

`new-api` reported slow database queries. The cluster currently stores application PVCs on Ceph. This investigation tested PostgreSQL on the same Ceph RBD StorageClass used by `new-api` to determine whether the storage backend is suitable for normal application workloads.

The test used a temporary PostgreSQL deployment in the `debug` namespace. The deployment was removed after the test.

## Test Setup

- Namespace: `debug`
- Helm chart: Bitnami `postgresql` chart `18.5.24`
- PostgreSQL app version reported by chart: `18.3.0`
- PostgreSQL client tools inside container: `pgbench`/`psql` `18.4`
- StorageClass: `ceph-block`
- PVC size: `10Gi`
- Volume type: Ceph RBD via `rook-ceph.rbd.csi.ceph.com`
- RBD pool: `ceph-blockpool`
- Filesystem: `ext4`
- RBD image features: `layering`
- Test database size after initialization and benchmark runs: about `762 MB`

The chart was deployed from the repository-local chart already used by `production/new-api`:

```bash
helm install ceph-pgbench production/new-api/charts/postgresql-18.5.24/postgresql \
  --namespace debug \
  --wait \
  --timeout 10m \
  --set auth.postgresPassword='<temporary-password>' \
  --set auth.username=bench \
  --set auth.password='<temporary-password>' \
  --set auth.database=bench \
  --set auth.usePasswordFiles=true \
  --set primary.persistence.storageClass=ceph-block \
  --set primary.persistence.size=10Gi \
  --set primary.resourcesPreset=none
```

PostgreSQL durability settings were the defaults:

```text
shared_buffers = 128MB
effective_cache_size = 4GB
synchronous_commit = on
fsync = on
full_page_writes = on
max_wal_size = 400MB
```

## Cluster State During Test

Ceph was not fully healthy during the benchmark:

```text
HEALTH_WARN
multiple OSDs experiencing slow operations in BlueStore
some placement groups were remapped and recovery/backfill was in progress
```

`ceph osd perf` showed several high commit/apply latencies during the test. The slowest observed OSD commit/apply latencies were in the low hundreds of milliseconds.

This means the measured write latency is partly affected by the cluster's current recovery/slow-op state. The results are still relevant because they show how PostgreSQL behaves under the current production storage condition.

## Initialization Result

`pgbench` was initialized with scale 50:

```bash
pgbench -h 127.0.0.1 -U bench -d bench -i -s 50
```

Result:

```text
done in 58.04 s
drop tables 0.00 s
create tables 0.40 s
client-side generate 51.18 s
vacuum 0.66 s
primary keys 5.80 s
```

PostgreSQL initialization did not reproduce an extremely slow database bootstrap. PVC provisioning, RBD attach, image pull, and PostgreSQL readiness completed in roughly one minute.

## Benchmark Results

All tests used prepared statements and ran inside the PostgreSQL pod against `127.0.0.1`, so the result focuses on PostgreSQL and storage behavior rather than Service networking.

```bash
pgbench -h 127.0.0.1 -U bench -d bench -M prepared -c <clients> -j <clients> -T 60
```

| Workload | Clients | TPS | Avg latency | Latency stddev |
| --- | ---: | ---: | ---: | ---: |
| Select only | 4 | 57,456 | 0.069 ms | 0.073 ms |
| TPC-B read-write | 4 | 18.6 | 214.3 ms | 108.0 ms |
| Simple update | 4 | 23.3 | 171.4 ms | 122.6 ms |
| Select only | 16 | 184,880 | 0.086 ms | 2.102 ms |
| TPC-B read-write | 16 | 68.5 | 233.3 ms | 185.7 ms |
| Simple update | 16 | 100.1 | 159.4 ms | 113.2 ms |

### Diagnostic Test: `synchronous_commit=off`

To isolate commit/fsync cost, the read-write test was repeated for 30 seconds with session-level `synchronous_commit=off`:

```bash
PGOPTIONS="-c synchronous_commit=off" pgbench ...
```

| Workload | Clients | TPS | Avg latency | Latency stddev |
| --- | ---: | ---: | ---: | ---: |
| TPC-B read-write, `synchronous_commit=off` | 4 | 709.1 | 5.64 ms | 44.7 ms |
| TPC-B read-write, `synchronous_commit=off` | 16 | 814.2 | 19.6 ms | 98.9 ms |

This is a large improvement over the default durable configuration:

- 4 clients: `18.6 TPS / 214 ms` -> `709 TPS / 5.6 ms`
- 16 clients: `68.5 TPS / 233 ms` -> `814 TPS / 19.6 ms`

The difference strongly indicates that the main bottleneck for write-heavy PostgreSQL workloads is the synchronous commit path: WAL flush, fsync, and Ceph RBD commit latency.

## Analysis

Hot read workloads are fine. Once data is in PostgreSQL shared buffers and the Linux page cache, PostgreSQL can serve tens of thousands to hundreds of thousands of simple read transactions per second. This suggests that ordinary indexed lookup queries in `new-api` should not be slow solely because the PVC is backed by Ceph, as long as the working set is cache-friendly and query plans are good.

Durable write workloads are slow. With `synchronous_commit=on` and `fsync=on`, read-write and update-heavy `pgbench` workloads stayed around tens of TPS, with average latency around 160-230 ms and high variance. Raising concurrency improved throughput but did not improve latency; it mostly added queueing and variability.

The diagnostic `synchronous_commit=off` test changes the conclusion sharply: PostgreSQL execution itself can handle far more throughput, but waiting for durable commit through Ceph RBD is expensive under the current cluster state.

The current Ceph health state matters. The test ran while Ceph had BlueStore slow operations and recovery/backfill in progress. That likely worsened write latency. However, this is still operationally relevant: if application databases share `ceph-block` with a cluster that can enter this state, user-facing write latency can degrade significantly.

## Impact on Daily Application Use

`ceph-block` can satisfy common read-mostly application workloads, especially metadata/config/query workloads where:

- reads are indexed and cache-friendly;
- write QPS is low;
- occasional write latency in the 100-300 ms range is acceptable;
- application-level slow query logs are not caused by missing indexes or inefficient SQL.

`ceph-block` is not a good fit for latency-sensitive or write-heavy PostgreSQL workloads under the current storage behavior, especially workloads requiring:

- low-latency synchronous commits;
- high write TPS;
- predictable p95/p99 write latency;
- frequent small transactions.

For `new-api`, this means Ceph RBD alone is unlikely to explain slow read queries if they are repeated/indexed reads. The next step should inspect PostgreSQL slow query logs, query plans, indexes, connection pool behavior, and cache hit ratios. If the slow logs are dominated by writes, updates, inserts, or transaction commits, Ceph RBD commit latency is a plausible contributor.

## Recommendations

1. Keep read-mostly PostgreSQL services on `ceph-block` if their write volume is modest and they tolerate occasional write latency spikes.

2. Do not place write-heavy or latency-sensitive PostgreSQL workloads on the current `ceph-block` pool without further storage tuning.

3. For `new-api`, investigate SQL-level causes before changing storage:
   - enable or inspect `pg_stat_statements`;
   - run `EXPLAIN (ANALYZE, BUFFERS)` for slow queries;
   - check missing indexes;
   - check PostgreSQL cache hit ratio;
   - distinguish query execution time from transaction commit time.

4. For services that are write-latency sensitive, consider one of:
   - a dedicated fast Ceph pool backed by SSD/NVMe OSDs;
   - scheduling database pods near faster OSD paths if topology matters;
   - reducing Ceph recovery/backfill impact during peak hours;
   - using local SSD/OpenEBS for databases where availability and backup strategy permit;
   - tuning PostgreSQL durability only when the application can tolerate data loss on crash.

5. Re-run this benchmark after Ceph returns to `HEALTH_OK`, because the current `HEALTH_WARN` and backfill state likely inflated write latency.

## Cleanup

The temporary Helm release was removed:

```bash
helm uninstall ceph-pgbench --namespace debug
```

The temporary `debug` namespace was deleted:

```bash
kubectl delete namespace debug
```

After deletion, `kubectl get ns debug` returned `NotFound`. A final direct PV lookup timed out against the Kubernetes API, but the namespace deletion command completed.
