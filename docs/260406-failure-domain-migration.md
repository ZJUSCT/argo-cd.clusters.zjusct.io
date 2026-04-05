# Failure Domain Migration: host -> osd

**Date:** 2026-04-06
**Cluster:** rook-ceph (Ceph Squid 19.2.3, Rook v1.19.1)
**Status:** In progress (ArgoCD synced, migration running)

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

## Migration timeline

- **Phase 1 (2026-04-06):** Emergency fixes for osd.11 near-full
  - `osd.11 reweight` reduced to 0.30
  - `osd_snap_trim_sleep` set to 0 (redundant -- already forced to 0 by mClock, see below)
  - See [260406-cephfs-osd-near-full.md](260406-cephfs-osd-near-full.md) for details

- **Phase 2 (2026-04-06):** Failure domain migration applied via ArgoCD
  - All 9 pools changed from `failureDomain: host` to `failureDomain: osd`
  - Rook created new CRUSH rules and applied them to each pool
  - Ceph began remapping ~573 PGs (backfill in progress)

- **PG 6.4 repair (2026-04-06):**
  - Pre-existing inconsistent PG on pool `cephfs-cephfs-hdd-data` (acting [22, 16])
  - 1 scrub error found during deep scrub at 21:35 UTC (before migration)
  - `ceph pg repair 6.4` executed -- repair confirmed, snap trim queue cleared (300 snapshots freed)
  - Post-repair deep scrub running to verify consistency

## Migration monitoring

```bash
# Watch PG states during migration
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status

# Monitor per-pool migration progress
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd pool stats

# Check for degraded PGs during backfill
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph pg dump pgs_brief | grep -v "active+clean" | head -20
```

## OSD tuning applied during migration

### mClock QoS scheduler (important discovery)

This cluster uses the mClock scheduler (default in Ceph Squid). mClock controls IOPS allocation across three client types:

| Client Type | Request Types |
|-------------|---------------|
| Client | External client I/O |
| Background recovery | Internal recovery requests |
| Background best-effort | Backfill, scrub, snap trim, PG deletion |

The active mClock profile determines the IOPS reservation, weight, and limit for each client type. **Individual config options like `osd_max_backfills` and `osd_snap_trim_sleep` are silently overridden by mClock** -- `ceph config set` reports success but the value is reverted to the profile default within seconds. This was discovered via warning logs on osd.13.

**Impact on earlier tuning attempts:**
- `osd_max_backfills` changes to 2 and 3 never took effect -- mClock held them at the profile default of 1. The observed throughput variations (43 vs 128 MiB/s) were caused by other factors, not by this setting.
- `osd_snap_trim_sleep` set to 0 in Phase 1 was redundant -- mClock already disables all sleep options (`osd_snap_trim_sleep`, `osd_recovery_sleep`, `osd_scrub_sleep`, etc.) when any profile is active.

### Current profile: `balanced` (default)

| Client Type | Reservation | Weight | Limit |
|-------------|-------------|--------|-------|
| Client | 50% | 1 | MAX |
| Background recovery | 50% | 1 | MAX |
| Background best-effort | MIN | 1 | 90% |

### Recommended: switch to `high_recovery_ops` profile

To prioritize the migration, switch the mClock profile:

```bash
ceph config set osd osd_mclock_profile high_recovery_ops
```

This allocates 70% IOPS reservation to background recovery at the expense of client I/O (30%):

| Client Type | Reservation | Weight | Limit |
|-------------|-------------|--------|-------|
| Client | 30% | 1 | MAX |
| Background recovery | 70% | 2 | MAX |
| Background best-effort | MIN | 1 | MAX |

Revert after migration completes:

```bash
ceph config set osd osd_mclock_profile balanced
```

### `osd_max_backfills` = 1 (mClock default, leave as-is)

Controls how many PGs each OSD can backfill simultaneously. Locked by mClock to the profile default of 1. Modifying it requires `osd_mclock_override_recovery_settings=true`, which is not recommended as the built-in profiles are optimized based on this value. Leave at default.

### `osd_snap_trim_sleep` = 0 (already mClock default)

This was set in Phase 1 but was redundant -- mClock forces all sleep options to 0. No action needed; no revert required.

### `osd_recovery_op_priority` = 63 (default, unchanged)

Controls the scheduling priority of recovery/backfill I/O relative to client I/O. Not modified -- the mClock profile is the correct mechanism to control recovery vs client IOPS balance.

## Post-migration cleanup

After all PGs reach `active+clean`:

- [ ] Revert mClock profile: `ceph config set osd osd_mclock_profile balanced`
- [ ] Clean up redundant `osd_snap_trim_sleep`: `ceph config rm osd osd_snap_trim_sleep`
- [ ] Remove orphaned CRUSH rules: `ceph osd crush rule rm <old-rule>`
- [ ] Reset all manual OSD reweights to 1.0 (workarounds from failureDomain: host era):
  ```
  ceph osd reweight osd.11 1.0
  ceph osd reweight osd.1 1.0
  ceph osd reweight osd.22 1.0
  ceph osd reweight osd.18 1.0
  ```
  With `failureDomain: osd`, the balancer distributes across all OSDs regardless of host, so manual reweights are no longer needed. Note: `ceph osd reweight` only affects PG placement, not the `ceph df` capacity calculation (`PGMap::get_rule_avail` in `src/mon/PGMap.cc` uses raw CRUSH item weights, ignoring reweight).
- [ ] Let the upmap balancer redistribute PGs evenly after reweight reset
- [ ] Verify cluster health is `HEALTH_OK` and pool MAX AVAIL has increased
