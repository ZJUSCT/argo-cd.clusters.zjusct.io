# CephFS OSD Near Full - Investigation Report

**Date:** 2026-04-06
**Cluster:** rook-ceph (Ceph Squid 19.2.3, Rook v1.19.1)
**Symptom:** `HEALTH_WARN` -- 1 OSD backfillfull, 19 pools backfillfull, 1 OSD with slow BlueStore operations.

## Cluster Status Summary

| Metric | Value |
|--------|-------|
| Health | `HEALTH_WARN` |
| Total raw | 90 TiB |
| Used | 31 TiB (34.22%) |
| Available | 59 TiB |
| OSDs | 29 up, 29 in |
| Pools | 24 pools, 1178 PGs |
| Objects | 52.12M objects, 15 TiB data |
| Recovery | 2.17% objects misplaced (47 remapped PGs) |
| Snap trim backlog | 478 PGs in `snaptrim_wait` |

## Critical Findings

### 1. osd.11 (m601, HDD) -- PRIMARY PROBLEM OSD

| Metric | Value |
|--------|-------|
| Usage | **92.92%** (1.7 TiB / 1.9 TiB) |
| Available | **135 GiB** |
| Status | **BACKFILLFULL** |
| Reweight | 0.90 (already reduced, but insufficient) |
| PGs | 23 PGs, dominated by pool 6 (`cephfs-cephfs-hdd-data`) |

This single OSD being at `backfillfull` triggers the cascading `POOL_BACKFILLFULL` warning across all 19 pools that have replicas on it.

### 2. m601 node is severely imbalanced

**HDD OSDs on m601** (all same 1.9 TiB disks):

| OSD | % Use | Used | Available | Reweight |
|-----|-------|------|-----------|----------|
| **osd.11** | **92.92%** | 1.7 TiB | 135 GiB | 0.90 -> **0.30** |
| osd.5 | 60.89% | 1.1 TiB | 748 GiB | 1.00 |
| osd.7 | 44.57% | 853 GiB | 1.0 TiB | 1.00 |
| osd.10 | 44.57% | 853 GiB | 1.0 TiB | 1.00 |
| osd.9 | 36.91% | 706 GiB | 1.2 TiB | 1.00 |
| osd.8 | 36.32% | 695 GiB | 1.2 TiB | 1.00 |

osd.11 carried **2.5x the data** of osd.8/osd.9, despite already having reweight 0.9 applied. The reduction was too conservative.

**NVMe OSDs on m601** are also heavily loaded:

| OSD | % Use | Available | Reweight |
|-----|-------|-----------|----------|
| **osd.18** | **85.91%** | 420 GiB | 0.81 |
| osd.1 | 73.21% | 958 GiB | 0.90 |

Compare with m600 NVMe: osd.12 (32%), osd.13 (34%) -- m601 NVMe OSDs carry ~2.5x more data.

**Per-host aggregate usage:**

| Host | Total | Used | % Use |
|------|-------|------|-------|
| **m601** | 19 TiB | **11 TiB** | **56.50%** |
| m600 | 26 TiB | 10 TiB | 38.14% |
| storage | 45 TiB | 9.9 TiB | 22.23% |

### 3. Snapshot purge backlog

478 PGs are queued in `snaptrim_wait` and 24 are actively trimming. Pool 6 (`cephfs-cephfs-hdd-data`) has `removed_snaps_queue [5~1a,20~13b]` -- deleted snapshots whose space has not yet been reclaimed. This space is still occupied on osd.11.

### 4. Active recovery from recent disruption

Approximately 11 hours ago, multiple OSDs restarted (10+ restarts on osd.6, 15, 16, 17, 18, 23-27). The cluster is still recovering with 47 remapped PGs and 2.17% misplaced objects. Recovery I/O was measured at 39 MiB/s.

### 5. osd.22 slow operations

osd.22 (m600, HDD, 78.38%) is reporting slow BlueStore operations, likely under I/O pressure from recovery and snap trimming.

## Root Cause

The primary issue is **severe data imbalance within the m601 host**. osd.11 accumulated far more PGs than its peers on the same host. The reweight reduction to 0.90 was applied too late and too conservatively -- it should have been reduced more aggressively earlier. Combined with a snapshot purge backlog holding onto deleted data, this pushed osd.11 past the backfillfull threshold.

## Actions Taken (Phase 1)

1. **Reduced osd.11 reweight from 0.90 to 0.30**:
   ```
   ceph osd reweight osd.11 0.30
   ```
   This triggers PG migration off osd.11 onto the under-loaded m601 peers (osd.7/8/9/10 at 36-45%). Ceph allows moving data away from a backfillfull OSD.

2. **Disabled snap trim sleep** to accelerate snapshot purge:
   ```
   ceph config set osd osd_snap_trim_sleep 0
   ```
   This removes the sleep between snap trim operations, helping clear the 478-PG `snaptrim_wait` queue faster and freeing space on osd.11.

## Remaining Recommendations (not yet applied)

### Phase 2 -- Stabilize m601 NVMe OSDs

3. **Reduce osd.18 reweight** (85.91%, next risk):
   ```
   ceph osd reweight osd.18 0.40
   ```

4. **Reduce osd.1 reweight** (73.21%):
   ```
   ceph osd reweight osd.1 0.50
   ```

### Phase 3 -- Address cephfs-hdd-data pool capacity

5. The `cephfs-cephfs-hdd-data` pool has **20 TiB used with only 663 GiB available** (pool-level). Even after rebalancing, this pool is nearing its capacity ceiling on the HDD tier:
   - **Option A**: Migrate some data to `cephfs-cephfs-nvme-data` (9.8 TiB used, 1037 GiB available)
   - **Option B**: Enable compression on the HDD pool (`ceph osd pool set cephfs-cephfs-hdd-data compression_algorithm snappy`)
   - **Option C**: Add more HDD OSDs to the cluster

### Phase 4 -- Post-recovery cleanup

6. Wait for recovery to complete (47 remapped PGs, ~2% misplaced objects). Once resolved, the `upmap` balancer will have room to further optimize placement.

7. After the cluster stabilizes, restore reweight values gradually or let the `upmap` balancer manage placement.
