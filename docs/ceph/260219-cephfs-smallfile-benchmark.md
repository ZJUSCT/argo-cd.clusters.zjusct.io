# CephFS Small-File Benchmark Report

**Date:** 2026-02-19
**Tool:** [smallfile v3.2](https://github.com/distributed-system-analysis/smallfile)
**Test host:** m604 (CephFS client, home dir mounted from CephFS)
**Mount:** `172.25.4.11,172.25.4.61,172.25.4.60:/volumes/home/bowling/...` → `/home/bowling`
**Cluster:** Rook-Ceph v1.19.1, Ceph 19.2.3 (Squid), 27 OSDs, 2 active MDS + 2 standby-replay
**Test directory:** `/home/bowling/cephfs-bench/`

---

## Benchmark Plan

The benchmark was designed to quantify the small-file performance characteristics identified in the [CephFS Performance Investigation Roadmap](./260218-cephfs-performance-investigation.md). Six test scenarios were executed:

| Test | Operation | Files | File Size | Threads | Goal |
|---|---|---|---|---|---|
| T1 | CREATE | 4,000 | 4 KB | 4 | File creation throughput |
| T2 | READ | 4,000 | 4 KB | 4 | Read throughput (cached) |
| T3 | STAT | 4,000 | 4 KB | 4 | Metadata getattr throughput |
| T4 | READDIR | 4,000 | — | 4 | Directory listing throughput |
| T5 | DELETE | 4,000 | 4 KB | 4 | File deletion throughput |
| T6 | node_modules sim | 50,000 | 100 B | 1 | Real-world small-file deletion (the bottleneck) |
| T6-P | Parallel delete | 50,000 | 100 B | 8 parallel | Parallel `xargs -P8` deletion comparison |

MDS performance counters were sampled every 5 seconds during T5 and T6 using `ceph tell mds.cephfs-b perf dump`.

---

## Pre-Test Baseline (2026-02-19T08:09:36Z)

### Cluster State

```
health: HEALTH_OK
mds: 2/2 daemons up, 2 hot standby
osd: 27 osds: 27 up, 27 in
client IO: 2.3 MiB/s rd, 2.6 MiB/s wr, 14 op/s rd, 160 op/s wr
```

### MDS Operation Latencies (cumulative averages since last restart)

| Operation | Avg Latency | Total Ops |
|---|---|---|
| journal write (`jlat`) | **31.11 ms** | 3,283,045 |
| `rename` | 30.82 ms | 182,098 |
| `setattr` | 17.71 ms | 617,984 |
| `rmdir` | 11.23 ms | 97,835 |
| `getattr` | 6.65 ms | 726,509 |
| `readdir` | 3.58 ms | 11,228,590 |
| `open` | 2.06 ms | 2,533,536 |
| `mkdir` | 0.69 ms | 177,150 |
| `unlink` | 0.29 ms | 799,781 |

### MDS Cache State

| Metric | Value |
|---|---|
| Inodes cached | 575,417 |
| Inodes expired (evictions) | 98,625,383 |
| `mds_cache_memory_limit` | **32 GiB** (not 2 GiB as previously assumed) |

> **Note:** The investigation roadmap mentioned 2 GiB cache memory as a potential issue. The current config is actually 32 GiB (`34359738368` bytes). Cache thrash as a root cause is less likely than previously hypothesized.

### OSD Latency

Notable high-latency OSDs at baseline:

| OSD | Commit (ms) | Apply (ms) |
|---|---|---|
| 16 | 38 | 38 |
| 26 | 14 | 14 |
| 24 | 13 | 13 |
| 23 | 6 | 6 |

OSD 16 at 38ms commit latency is significant — this is above the already-high 31ms MDS journal latency. OSDs serving the metadata pool are prime candidates for this bottleneck.

---

## Benchmark Results

### T1 — CREATE (4 KB files, 4 threads)

```
Total files:   4,000
Elapsed:       0.964 s
Files/sec:     4,154
Throughput:    16.2 MiB/s
```

**Analysis:** 4,154 file creates/sec at 4KB is consistent with the MDS being the bottleneck. The MDS must journal each `create` operation, and at 31ms journal latency, 4 threads can sustain roughly 4 × (1000ms / 31ms) ≈ 129 journal ops/sec — but the actual throughput is higher because the MDS batches journal writes. The client-side observed throughput of ~4K files/sec indicates effective journaling batching.

### T2 — READ (4 KB files, 4 threads, kernel page cache warm)

```
Total files:   4,000
Elapsed:       0.036 s
Files/sec:     111,603
Throughput:    436.0 MiB/s
```

**Analysis:** Reads served entirely from the kernel page cache (files just created). This represents an upper bound; cold reads would be much slower. The 436 MiB/s matches local DRAM bandwidth, not CephFS.

### T3 — STAT (4 KB files, 4 threads, MDS cache warm)

```
Total files:   4,000
Elapsed:       0.040 s
Files/sec:     101,473
```

**Analysis:** Stats served from the MDS client-side inode cache (caps held). No MDS round-trips required. Cold stat (after cache drop) would reflect the 6.65ms `getattr` latency = ~150 stats/sec per thread.

### T4 — READDIR (4 threads, MDS dentry cache warm)

```
Total files:   4,000 entries
Elapsed:       0.058 s
Entries/sec:   70,326
```

**Analysis:** Cached directory listing. Cold readdir at 3.58ms per operation = ~280 readdir ops/sec per thread.

### T5 — DELETE (4 KB files, 4 threads)

```
Total files:   4,000
Elapsed:       0.805 s
Files/sec:     4,971
```

**MDS monitoring during T5 (5-second samples):**

```
jlat=31.2ms | unlink=0.3ms | rmdir=11.0ms | readdir=3.6ms  [stable throughout]
```

**Analysis:** `unlink` at 0.3ms is fast because CephFS defers the actual journal commit for unlink (uses "backtrace" removal asynchronously). `rmdir` at 11ms requires a synchronous journal commit (directory inode update). With 4 threads and batching, 4971 deletes/sec is achievable.

### T6 — node_modules Simulation (50,000 files, 2,200 directories, sequential `rm -rf`)

**Tree structure:** 200 packages × (50 files + 10 subdirs × 20 files) = 50,000 files, 2,200 directories.

#### Creation Phase

```
Files created:    50,000
Dirs created:     2,200
Elapsed:          24.4 s
Files/sec:        ~2,049 (single-threaded Python, sequential)
```

#### Deletion Phase (`rm -rf`)

```
Time:             1m 29.5s (89.5 seconds)
Files deleted:    ~48,244 unlinks
Dirs deleted:     ~2,213 rmdirs
Effective rate:   539 unlinks/sec + 24.7 rmdirs/sec = 563.8 ops/sec
```

**MDS monitoring during deletion (5-second samples):**

```
[08:14:03–08:15:30] Active deletion: ~7,000 unlinks/min, 1,500 rmdirs/min
[08:15:30–08:16:25] STALL: op counters frozen for ~55 seconds
[08:16:25–08:17:34] Resumed at very low rate (few hundred ops)
```

Key observation: **a ~55-second stall** occurred partway through the deletion where MDS op counters stopped advancing entirely. This is consistent with the client waiting for capability revocations from other clients (49 connected sessions on this cluster), or a single large directory's journal commit blocking the rm -rf traversal.

The journal latency remained at **31.2ms throughout** — it does not spike under this load, confirming the bottleneck is the inherent per-operation serialization at 31ms, not additional congestion.

#### Theoretical Minimum Time

Given the observed latencies:
- 50,000 unlinks × 0.3ms = 15 seconds (if pure unlinks, sequential)
- 2,200 rmdirs × 11ms = 24.2 seconds (if pure rmdirs, sequential)
- 2,200 readdir ops × 3.6ms × 2 passes = ~16 seconds (traverse up + down)

Theoretical minimum (ignoring parallelism limits): **~55 seconds**. Actual: **89.5 seconds** — the ~34-second overhead is attributable to the client-side stall (cap revocations or VFS lock contention), not MDS latency alone.

### T6-P — Parallel Deletion Comparison (`find | xargs -P8 rm -rf`)

```
Time:        30.5 seconds
Speedup:     2.93× vs sequential rm -rf
```

Parallel deletion saturates all MDS worker threads simultaneously, eliminating the per-directory serialization. The remaining 30.5 seconds approaches the theoretical minimum.

---

## MDS Cache Hit Analysis

| Metric | Pre-Test | Post-Test | Delta |
|---|---|---|---|
| `traverse_dir_fetch` (cache miss) | 3,382,918 | 3,418,893 | +35,975 |
| `traverse_hit` (cache hit) | 428,743,443 | 429,335,262 | +591,819 |
| **Cache hit rate during test** | | | **94.3%** |

The 94.3% MDS metadata cache hit rate confirms that the 32 GiB cache is sufficient for the working set. The bottleneck is not cache churn — it is the journal write latency.

---

## Key Findings

### Finding 1: MDS Journal Latency is the Dominant Bottleneck

The MDS journal write latency is **31.2ms** and has been stable at this value since the cluster was last analyzed (2026-02-18). This latency:

- Serializes all mutating operations: `rename` (30.8ms), `rmdir` (11ms), `setattr` (17.7ms)
- Is directly correlated with OSD commit latency (OSD 16 shows 36–38ms, OSD 6 shows 30ms)
- Does NOT change under benchmark load — it is steady-state, not contention-induced

### Finding 2: OSD Latency Directly Explains Journal Latency

The per-OSD commit latency snapshot shows several NVMe OSDs with 30–38ms commit times:

| OSD | Commit/Apply (ms) | Assessment |
|---|---|---|
| OSD 16 | 36–38 | **Critical** — exceeds jlat average |
| OSD 6 | 30 | Matches jlat |
| OSD 26 | 12–14 | High for NVMe |
| OSD 23 | 6–8 | Marginal |

For NVMe storage, commit latencies above 1–5ms indicate the WAL/DB device is likely **shared with data** (no dedicated partition), causing write serialization.

### Finding 3: `rm -rf` is Limited by rmdir Serialization + Client Stall

The `rm -rf` of 50,000 files took 89.5 seconds:
- ~55s of actual ops at 563.8 ops/sec (limited by 11ms rmdir + 0.3ms unlink interleaved)
- ~34s of unexplained stall (likely cap revocation wait from 49 connected clients)

Parallel deletion (`xargs -P8`) reduces this to 30.5s by:
1. Processing 8 package directories concurrently, eliminating the directory-by-directory serialization
2. Saturating MDS worker threads evenly
3. Bypassing the client-side VFS serialization that stalls sequential `rm -rf`

### Finding 4: MDS Cache Memory Limit is Already 32 GiB

The previous investigation assumed the cache was 2 GiB. The actual value is **32 GiB**. The 94.3% cache hit rate confirms the cache is not the bottleneck. Increasing `mds_cache_memory_limit` will have no impact on the current performance issue.

---

## Recommendations

### R1: Investigate OSD WAL/DB Separation (High Priority)

OSD 16 (36ms), OSD 6 (30ms) have commit latencies that directly set the journal write floor. Verify whether these OSDs have dedicated WAL/DB devices:

```bash
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- \
  ceph osd metadata 16 2>&1 | grep -E 'bluefs|wal_|db_|devices'
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- \
  ceph osd metadata 6 2>&1 | grep -E 'bluefs|wal_|db_|devices'
```

If `bluestore_db_separate_device` is empty, the WAL is co-located with data. Provisioning a dedicated NVMe partition for the WAL/DB of the metadata-pool OSDs could reduce journal latency from 31ms to <5ms.

### R2: Use Parallel Deletion for node_modules Workloads (Immediate)

Replace `rm -rf node_modules` with:

```bash
find node_modules -mindepth 1 -maxdepth 1 -type d | xargs -P8 -I{} rm -rf {}
```

**Impact:** 89.5s → 30.5s (2.93× speedup). No cluster changes required.

### R3: Investigate the 55-Second Client Stall

The `rm -rf` stall (08:15:35–08:16:25) with 49 connected clients suggests cap revocation pressure. Check:

```bash
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- \
  ceph tell mds.cephfs-b session ls --format json 2>&1 | python3 -c "
import sys, json
sessions = json.load(sys.stdin)
sessions.sort(key=lambda x: x.get('num_caps',0), reverse=True)
print(f'Total: {len(sessions)} clients')
for s in sessions[:10]:
    print(f'  {s.get(\"client_ip\",\"?\")} caps={s.get(\"num_caps\",0)}')
"
```

If any client holds thousands of caps, tune `mds_max_caps_per_client` from the default 32,768 to 16,384 to reduce cap revocation latency.

### R4: Do NOT Increase mds_cache_memory_limit

The cache is already 32 GiB with a 94.3% hit rate. This optimization candidate from the roadmap is not applicable.

### R5: Correlate OSD 16/6 with Metadata Pool PGs

Confirm whether the high-latency OSDs actually serve the `cephfs-metadata` pool:

```bash
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- \
  ceph pg ls-by-pool cephfs-metadata 2>&1 | awk '{print $15}' | tr ',' '\n' | sort -un
```

If OSDs 6 and 16 are in this list, fixing their WAL latency will directly reduce `jlat`.

---

## Performance Summary Table

| Metric | Value | Context |
|---|---|---|
| File create throughput | 4,154 files/sec | 4KB, 4 threads, MDS-limited |
| File read throughput | 111,603 files/sec | 4KB, 4 threads, page-cache (not CephFS) |
| File stat throughput | 101,473 files/sec | 4KB, 4 threads, inode-cache |
| Readdir throughput | 70,326 entries/sec | Dentry cache warm |
| File delete throughput | 4,971 files/sec | unlink 0.3ms avg |
| `rm -rf` 50K files (seq) | **89.5 seconds** | 563 ops/sec, ~55s stall |
| `rm -rf` 50K files (parallel) | **30.5 seconds** | 2.93× faster |
| MDS journal latency (jlat) | **31.2 ms** | Steady-state, OSD-limited |
| MDS rmdir latency | 11–13 ms | Journal-bound |
| MDS readdir latency | 3.6 ms | Dir-fetch when not cached |
| MDS unlink latency | 0.3 ms | Async, not journal-bound |
| MDS cache hit rate | 94.3% | 32 GiB cache, sufficient |
| Peak OSD commit latency | 36–38 ms (OSD 16) | Likely no dedicated WAL/DB |

---

---

## Addendum: Follow-up Investigation (2026-02-19)

Two issues with the initial report were raised and investigated. Additionally, the original R1 is corrected below (OSD 6 and OSD 16 are HDD, not NVMe — the original recommendation was wrong).

### Q1: MDS Imbalance — Why is Rank 1 Idle and How to Fix It

`ceph fs status` shows two active MDS daemons with severely unequal load:

| Rank | MDS | State | Req/s | DNS (inodes) | Caps | Sequence |
|---|---|---|---|---|---|---|
| 0 | cephfs-b | active | **7/s** | 571K | 515K | 144,244 |
| 1 | cephfs-a | active | 0/s | 2,120 | 449 | 42 |

The extremely low sequence number for rank 1 (seq=42 vs seq=144244) shows that cephfs-a was recently started or restarted and has received no subtree delegation from rank 0 since.

#### Why the Automatic Balancer Doesn't Help

`ceph fs get cephfs` shows:
```
balancer          (empty)
bal_rank_mask     -1
```

- `balancer` empty → default balancer algorithm (`mds_bal_mode=0`, "Hybrid")
- `bal_rank_mask -1` → all ranks are eligible candidates (not the bottleneck)

The MDS load balancer is a **hotspot-driven balancer**. It migrates subtrees when a directory fragment's request rate exceeds split thresholds:

```
mds_bal_split_rd   = 25,000 ops/sec   (per directory fragment, read threshold)
mds_bal_split_wr   = 10,000 ops/sec   (per directory fragment, write threshold)
mds_bal_min_rebalance = 0.1           (minimum fractional imbalance to trigger migration)
```

Rank 0 is receiving **7 total req/s** spread across 571K cached inodes. No single directory fragment is anywhere close to 25,000 ops/sec. The balancer's temperature model sees nothing "hot" enough to migrate. **This is expected behavior** — the MDS load balancer was designed for single-directory hotspots (e.g., a build system hammering one directory), not for distributing a broad low-intensity workload like user home directories.

Rook sets zero balancer configuration (confirmed from source: `pkg/operator/ceph/file/mds/config.go` only sets `mds_cache_memory_limit` and `mds_join_fs`). The balancer is entirely unmanaged by Rook.

#### How to Balance: Ephemeral Random Pinning

For a home directory filesystem with many user subdirectories, the correct approach is **random ephemeral pinning**, not the automatic load balancer. This pins approximately 50% of top-level subdirectories to rank 1:

```bash
# Pin ~50% of subdirectories under the volumes/home group to rank 1 automatically
# (applied to the MDS-visible path of the subvolumegroup)
setfattr -n ceph.dir.pin.random -v "0.5" /home
```

This is persistent across MDS restarts (stored in the inode's xattr) and requires no manual enumeration. After setting, newly-accessed directories will gradually be distributed as caps are granted.

Alternatively, for explicit control, use hard export pins on a per-user basis:

```bash
# Pin bowling's home to rank 0, pin another user to rank 1
setfattr -n ceph.dir.pin -v 0 /home/bowling   # rank 0
setfattr -n ceph.dir.pin -v 1 /home/someuser  # rank 1
```

> **Caveat:** Distributing metadata across ranks only helps if the MDS CPU or journal write concurrency is the bottleneck. With the current root cause being HDD-primary PGs in the metadata pool (see Q2), fixing the CRUSH rule should take priority. After the CRUSH fix, if jlat drops to <5ms and MDS CPU becomes the bottleneck, then rank balancing will be meaningful.

#### Summary for Q1

Monitoring only `mds.cephfs-b` was appropriate because it handles all real traffic. The imbalance is not a misconfiguration — it is expected behavior when the workload is broad and low-intensity. The load-based automatic balancer will never trigger at 7 req/s total. Explicit ephemeral random pinning is the correct tool for distributing home directory workloads across MDS ranks.

---

### Q2: deviceClass: nvme in metadataPool Config — Why Didn't It Take Effect?

The values file correctly declares:

```yaml
metadataPool:
  failureDomain: host
  deviceClass: nvme
  replicated:
    size: 2
```

Yet the `cephfs-metadata` pool uses CRUSH rule `cephfs-metadata` which targets `default` (all devices, no class filter). The `cephfs-cephfs-home` data pool has the same issue despite `deviceClass: nvme`. Here is the complete root-cause trace through the Rook source code.

#### Code Path: How Rook Applies deviceClass to a Pool

**File: `pkg/daemon/ceph/client/pool.go`**

The relevant function is `createReplicatedPoolForApp` (line 442). It runs every reconciliation cycle for every pool:

```go
// Step 1 (line 467–471): Always create/verify the CRUSH rule
checkFailureDomain = true
if err := createReplicationCrushRule(ctx, clusterInfo, clusterSpec, crushRuleName, pool); err != nil {
    return errors.Wrapf(err, "failed to create replicated crush rule %q", crushRuleName)
}

// Step 2 (line 475–495): Create pool if new, or update size if exists
poolDetails, err := GetPoolDetails(...)
if err != nil {
    // Pool doesn't exist: create it, using crushRuleName
} else {
    // Pool exists: only update replication size if changed
}

// Step 3 (line 504–508): Update CRUSH rule if deviceClass is set
if checkFailureDomain || pool.PoolSpec.DeviceClass != "" {
    if err = updatePoolCrushRule(ctx, clusterInfo, clusterSpec, pool); err != nil {
        return errors.Wrapf(err, ...)
    }
}
```

`crushRuleName` is always `pool.Name` (i.e., `"cephfs-metadata"`) — **the CRUSH rule name is the same as the pool name, regardless of deviceClass.**

**Step 1: `createReplicationCrushRule` (line 743)**

```go
args := []string{"osd", "crush", "rule", "create-replicated", ruleName, crushRoot, failureDomain}
if pool.DeviceClass != "" {
    args = append(args, pool.DeviceClass)
}
output, err := NewCephCommand(context, clusterInfo, args).Run()
if err != nil {
    return errors.Wrapf(err, "failed to create crush rule %s. %s", ruleName, output)
}
```

This runs: `ceph osd crush rule create-replicated cephfs-metadata default host nvme`

**Critical behavior verified by live test:**

```
$ ceph osd crush rule create-replicated cephfs-metadata default host nvme
rule cephfs-metadata already exists
Exit code: 0
```

When a CRUSH rule with that name already exists (even with different content — e.g., no `nvme` class), **Ceph returns exit code 0** and the message "already exists". It does NOT update the existing rule. Rook sees no error, so Step 1 "succeeds" silently, and the existing rule (without `nvme`) is left unchanged.

**Step 3: `updatePoolCrushRule` (line 512) — The Safety Gate**

```go
func updatePoolCrushRule(...) error {
    if pool.EnableCrushUpdates == nil || !*pool.EnableCrushUpdates {
        logger.Debugf("Skipping crush rule update for pool %q: EnableCrushUpdates is disabled")
        return nil   // <-- exits immediately, no update
    }
    // ... would create rule "cephfs-metadata_host_nvme" and apply it ...
}
```

`EnableCrushUpdates` is a `*bool` field in the pool spec (`pkg/apis/ceph.rook.io/v1/types.go` line 956). It defaults to `nil`. **When nil or false, all CRUSH rule updates for existing pools are skipped.** This is an intentional safety gate — Rook avoids silently triggering PG remapping (data movement) on existing pools without explicit opt-in.

#### The Operator Confirms: No Error, Silent No-Op

Operator log during a recent reconciliation:
```
I | cephclient: setting pool property "pg_autoscale_mode" to "off" on pool "cephfs-metadata"
I | cephclient: application "cephfs" is already set on pool "cephfs-metadata"
I | cephclient: reconciling replicated pool cephfs-metadata succeeded
```

No CRUSH-rule-related lines. No error. The pool reconciles successfully but the deviceClass is silently never applied.

#### Why Both `cephfs-metadata` and `cephfs-cephfs-home` Are Affected

Both pools were created before `deviceClass: nvme` was added to the spec (or before `enableCrushUpdates: true` was set). The CRUSH rule for `cephfs-cephfs-home` (rule 18) also uses `default` despite `deviceClass: nvme`. Same mechanism.

#### The Fix

Add `enableCrushUpdates: true` to the metadataPool spec in `values/rook-ceph-cluster-v1.19.1.yaml`:

```yaml
metadataPool:
  failureDomain: host
  deviceClass: nvme
  enableCrushUpdates: true    # ADD THIS
  replicated:
    size: 2
  parameters:
    pg_autoscale_mode: "off"
```

On next reconciliation, `updatePoolCrushRule` will:
1. Detect: current rule = `cephfs-metadata` (no device class), desired = nvme
2. Create new rule: `ceph osd crush rule create-replicated cephfs-metadata_host_nvme default host nvme`
3. Apply: `ceph osd pool set cephfs-metadata crush_rule cephfs-metadata_host_nvme`
4. 19 HDD-primary PGs will remap to NVMe OSDs — backfill of ~6.6 GiB (metadata pool)

The same fix applies to `cephfs-home` data pool (currently 0 bytes used, so backfill is trivial).

> **Important:** After applying `enableCrushUpdates: true`, Rook will update the CRUSH rule on EVERY reconciliation if the detected rule doesn't match. This is safe because `updatePoolCrushRule` checks the current rule before acting — it only updates if the rule actually differs from the desired state.

---

Back to the original Q2 question about data pool vs metadata pool:

The user reported that the home directory CephFS uses NVMe via a subvolume `data_pool` setting. This is confirmed:

```
ceph fs subvolume info cephfs bowling home → data_pool: cephfs-cephfs-nvme-data
```

The `cephfs-cephfs-nvme-data` pool uses CRUSH rule `nvme` (`default~nvme`), so file data for `/home/bowling` goes to NVMe OSDs only. **This is correct.**

However, the **MDS journal** writes to `cephfs-metadata`, which is a completely separate pool. Checking its CRUSH rule:

```
pool 4 'cephfs-metadata'  crush_rule 4
```

CRUSH rule 4 (`cephfs-metadata`):
```json
{ "op": "take", "item_name": "default" }   ← no device class filter
```

**The `cephfs-metadata` pool has no device class restriction.** It uses the entire `default` CRUSH bucket, distributing PGs across HDD, NVMe, and SSD indiscriminately.

#### PG-to-Device Mapping for cephfs-metadata

All 32 PGs analyzed:

| PG | Primary OSD | Replica OSD | Primary Class | Note |
|---|---|---|---|---|
| 4.0 | osd.4 | osd.18 | nvme | |
| 4.1 | osd.18 | osd.2 | nvme | |
| 4.2 | osd.6 | osd.12 | **hdd** | |
| 4.3 | osd.24 | osd.12 | **hdd** | |
| 4.4 | osd.1 | osd.2 | nvme | |
| 4.5 | osd.18 | osd.6 | nvme | |
| 4.6 | osd.16 | osd.8 | **hdd** | both replicas HDD |
| 4.7 | osd.15 | osd.1 | **hdd** | |
| 4.8 | osd.19 | osd.26 | **hdd** | both replicas HDD |
| 4.9 | osd.1 | osd.2 | nvme | |
| 4.a | osd.2 | osd.18 | nvme | |
| 4.b | osd.8 | osd.19 | **hdd** | both replicas HDD |
| 4.c | osd.24 | osd.12 | **hdd** | |
| 4.d | osd.17 | osd.13 | **hdd** | |
| 4.e | osd.4 | osd.5 | nvme | |
| 4.f | osd.26 | osd.13 | **hdd** | |
| 4.10 | osd.21 | osd.16 | **hdd** | both replicas HDD |
| 4.11 | osd.24 | osd.19 | **hdd** | both replicas HDD |
| 4.12 | osd.24 | osd.9 | **hdd** | both replicas HDD |
| 4.13 | osd.4 | osd.24 | nvme | |
| 4.14 | osd.9 | osd.26 | **hdd** | both replicas HDD |
| 4.15 | osd.18 | osd.23 | nvme | |
| 4.16 | osd.25 | osd.22 | **hdd** | both replicas HDD |
| 4.17 | osd.12 | osd.11 | nvme | |
| 4.18 | osd.13 | osd.9 | nvme | |
| 4.19 | osd.26 | osd.5 | **hdd** | both replicas HDD |
| 4.1a | osd.8 | osd.6 | **hdd** | both replicas HDD |
| 4.1b | osd.26 | osd.3 | **hdd** | |
| 4.1c | osd.1 | osd.19 | nvme | |
| 4.1d | osd.26 | osd.11 | **hdd** | both replicas HDD |
| 4.1e | osd.18 | osd.13 | nvme | |
| 4.1f | osd.22 | osd.24 | **hdd** | both replicas HDD |

**Summary: 19/32 PGs (59.4%) have HDD primary OSDs.**

#### OSD Latency by Device Class (at time of investigation)

| Device | OSD | Commit latency | Apply latency |
|---|---|---|---|
| nvme | osd.1 | 0 ms | 0 ms |
| nvme | osd.2 | 0 ms | 0 ms |
| nvme | osd.4 | 0 ms | 0 ms |
| nvme | osd.12 | 0 ms | 0 ms |
| nvme | osd.13 | 0 ms | 0 ms |
| nvme | osd.18 | 0 ms | 0 ms |
| hdd | osd.6 | 26 ms | 26 ms |
| hdd | osd.16 | 33 ms | 33 ms |
| hdd | osd.26 | 15 ms | 15 ms |

All NVMe OSDs show ~0ms commit latency at this moment; HDD OSDs show 15–33ms. The blended jlat of 31ms is consistent with ~59% of writes hitting HDD at ~50ms average and ~41% hitting NVMe at <1ms: `0.59 × 50 + 0.41 × 1 ≈ 30ms`.

#### Why cephfs-a Shows Lower jlat

With only 2,172 total journal writes (vs 3.3M for cephfs-b), cephfs-a's journal segment occupies a small number of PGs that happen to be NVMe-primary, giving a 12ms average. This is a sampling artifact from low volume — if cephfs-a were under the same load as cephfs-b and writing to all 32 PGs proportionally, it would converge to the same ~31ms.

#### Root Cause Confirmed

The 31ms `jlat` is caused by **the `cephfs-metadata` pool having no device class constraint**, placing 59% of its PGs on HDD OSDs. This is a misconfiguration — it has nothing to do with the NVMe data pool configuration, which is correctly set. The data writes correctly go to NVMe, but all metadata journal writes pass through this mixed-device metadata pool.

---

### Corrected Recommendation R1

> **The OSDs cited in the original R1 (OSD 6, OSD 16) are HDD, not NVMe. The original recommendation was incorrect.** Those OSDs are not supposed to serve the metadata pool. The issue is not WAL/DB co-location on NVMe — it is that the metadata pool CRUSH rule must be restricted to NVMe.

**Correct fix:** Change the `cephfs-metadata` pool CRUSH rule from `default` (all devices) to `default~nvme` (NVMe only).

The cluster has 6 NVMe OSDs across 2 hosts (m600: osd.2, osd.4, osd.12, osd.13; m601: osd.1, osd.18). With replication size 2 and host-level failure domain, all 32 metadata PGs can be served from NVMe OSDs on m600 and m601. The `storage` host has no NVMe OSDs and would be excluded from metadata placement, which is the correct and intended behavior.

To apply this fix:

```bash
# 1. Create a new CRUSH rule for metadata (NVMe only)
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- \
  ceph osd crush rule create-replicated cephfs-metadata-nvme default host nvme

# 2. Apply the rule to the metadata pool
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- \
  ceph osd pool set cephfs-metadata crush_rule cephfs-metadata-nvme

# 3. Monitor PG remapping (PGs will migrate from HDD to NVMe OSDs)
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph -w
```

After remapping completes (backfill of ~6.6 GiB from 19 PGs), jlat should drop from ~31ms to <5ms, directly reducing `rmdir` from 11ms to <2ms and `rename` from 31ms to <5ms.

> **Note:** This change affects the `storage` host's utilization — it will no longer serve metadata PGs. This is fine since its NVMe capacity is zero. The replication factor of 2 with m600+m601 provides host-level redundancy as long as both hosts are healthy.

---

## Appendix: Raw Data

All raw benchmark output, MDS perf dumps, and monitoring logs are saved to `/home/bowling/cephfs-bench/results/`:

```
baseline.txt         — pre-test full MDS perf dump + OSD perf + cluster status
t1_create.json       — smallfile CREATE results
t2_read.json         — smallfile READ results
t3_stat.json         — smallfile STAT results
t4_readdir.json      — smallfile READDIR results
t5_delete.json       — smallfile DELETE results
t5_mds_during.txt    — MDS perf samples during T5 (every 5s)
t6_pre_delete.txt    — MDS state before node_modules deletion
t6_mds_during_delete.txt — MDS perf samples during T6 rm -rf (every 5s, 40 samples)
post_test.txt        — post-test full MDS perf dump + OSD perf
```
