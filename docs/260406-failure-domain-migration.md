# Failure Domain Migration: host -> osd

**Date:** 2026-04-06
**Cluster:** rook-ceph (Ceph Squid 19.2.3, Rook v1.19.1)
**Status:** Pending (values edited, awaiting ArgoCD sync)

## Problem

With `failureDomain: host` and `replicated: size: 2` across only 3 hosts, the effective usable capacity is bottlenecked by the smallest host per device class. The advertised 90 TiB raw capacity is misleading -- the actual usable data is approximately 12.8 TiB.

### Root cause

The CRUSH rule runs `chooseleaf_firstn 2 type host`, which forces Ceph to pick 2 different hosts for each replica pair. Each host must hold approximately `replica_size / num_hosts` of the total raw data. The smallest host in each device class determines the ceiling.

### Capacity comparison

**Per tier with `failureDomain: host`:**

| Tier | Hosts with tier | Smallest host cap | Max raw | Usable (÷2) | Total raw | Wasted |
|------|-----------------|-------------------|---------|-------------|-----------|--------|
| NVMe | 2 (m600, m601) | 6.4T (m601) | 12.8T | 6.4T | 23.3T | 45% |
| HDD | 3 | 7.6T (m600) | 11.4T | 5.7T | 62.6T | **82%** |
| SSD | 3 | 0.9T (storage) | 1.35T | 0.7T | 4.4T | 69% |
| **Total** | | | | **~12.8T** | **90T** | **~86%** |

**Per tier with `failureDomain: osd`:**

| Tier | Total raw | Usable (÷2) | Improvement |
|------|-----------|-------------|-------------|
| NVMe | 23.3T | **11.7T** | +82% |
| HDD | 62.6T | **31.3T** | +449% |
| SSD | 4.4T | **2.2T** | +226% |
| **Total** | **90T** | **45T** | **+252%** |

### Per-host disk inventory

```
m600 (26.2T):  HDD 7.6T (4x1.9T) | NVMe 16.9T (2.9+3.5+7.0+3.5) | SSD 1.7T (894G+894G)
m601 (19.6T):  HDD 11.4T (6x1.9T) | NVMe 6.4T (3.5+2.9)           | SSD 1.8T (894G+954G)
storage (44.5T): HDD 43.6T (4x3.6T+4x7.3T) | SSD 0.9T (954G)
```

## Tradeoff: host failure risk

With `failureDomain: osd`, both replicas of a PG can land on the same host. If that host fails, those PGs lose all copies.

**HDD tier (18 OSDs: 4 on m600, 6 on m601, 8 on storage):**
- Both replicas on storage: `C(8,2)/C(18,2)` = **18.3%** of PGs
- Both replicas on m601: `C(6,2)/C(18,2)` = **9.8%** of PGs
- Both replicas on m600: `C(4,2)/C(18,2)` = **3.9%** of PGs
- Total at risk on any single host failure: up to **18.3%**

**NVMe tier (6 OSDs: 4 on m600, 2 on m601):**
- Both replicas on m600: `C(4,2)/C(6,2)` = **40%** of PGs
- Both replicas on m601: `C(2,2)/C(6,2)` = **6.7%** of PGs
- Total at risk: up to **40%**

## Changes applied

All 9 pools in `production/rook-ceph/values/rook-ceph-cluster-v1.19.1.yaml` changed from `failureDomain: host` to `failureDomain: osd`. All pools have `enableCrushUpdates: true` to allow Rook to manage the CRUSH rule migration.

| Pool | Type | Device Class | Line |
|------|------|-------------|------|
| `ceph-blockpool` | RBD block pool | (all) | 686 |
| `cephfs-metadata` | CephFS metadata | nvme | 759 |
| `cephfs-data0` | CephFS data | (all) | 768 |
| `cephfs-hdd-data` | CephFS data | hdd | 777 |
| `cephfs-nvme-data` | CephFS data | nvme | 786 |
| `cephfs-ssd-data` | CephFS data | ssd | 795 |
| `cephfs-home` | CephFS data | nvme | 804 |
| `ceph-objectstore` metadata | RGW metadata | hdd | 881 |
| `ceph-objectstore` data | RGW data | hdd | 890 |

## How the migration works (Rook source)

When Rook detects a failure domain change on a pool with `enableCrushUpdates: true` (`rook/pkg/daemon/ceph/client/pool.go:512-576`):

1. Creates a new CRUSH rule: `ceph osd crush rule create-replicated <pool>_<failureDomain>[_<deviceClass>] default osd`
2. Applies it: `ceph osd pool set <pool> crush_rule <new-rule>`
3. Ceph remaps all PGs to conform to the new placement (`chooseleaf_firstn 2 type osd`)
4. PGs transition through `active+remapped+backfilling` states

## Pre-apply checklist

Before pushing, ensure:

- [ ] osd.11 reweight migration from earlier (Phase 1) has stabilized
- [ ] Cluster recovery from the ~11h-ago disruption is complete (no misplaced objects)
- [ ] No OSDs in backfillfull/nearfull state

## Post-apply monitoring

```bash
# Watch PG states during migration
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status

# Monitor per-pool migration progress
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd pool stats

# Check for degraded PGs during backfill
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph pg dump pgs_brief | grep -v "active+clean" | head -20
```

## OSD tuning options (reference)

### `osd_max_backfills`

Controls how many PGs each OSD can backfill simultaneously. Default is 1.

When the CRUSH rule changes, Ceph must remap and backfill PGs to their new OSD locations. With 1178 PGs and only 1 backfill slot per OSD (29 OSDs = 29 concurrent backfills), the migration could be slow. Increasing to 2 doubles throughput but also doubles the I/O load on each OSD.

Recommendation: set to `2` during migration, revert to `1` after:
```
ceph config set osd osd_max_backfills 2
```

### `osd_recovery_op_priority`

Controls the priority of recovery/backfill I/O operations relative to client I/O. Default is 63 (on a scale where client ops are typically priority 63, scrub is lower). Setting it to a lower number (e.g., 1) makes recovery ops yield to client I/O, reducing client-visible latency impact during migration. Setting it higher makes recovery finish faster but may cause client I/O latency spikes.

Recommendation: leave at default (63) if you want faster migration. Set to `1` if you need to protect client I/O latency:
```
ceph config set osd osd_recovery_op_priority 1
```

These are optional tuning knobs, not required for the migration itself. Apply them via `kubectl exec` into the rook-ceph-tools pod if desired.
