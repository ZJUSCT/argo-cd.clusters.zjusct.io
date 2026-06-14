# CephFS "No space left on device" on File Deletion - Investigation Report

**Date:** 2026-04-05
**Cluster:** rook-ceph (Ceph Squid 19.2.3)
**Symptom:** Users cannot delete files on CephFS mounts despite 60.6 TB available space.

## Symptom

```
rm: cannot remove 'conf-storage/registry/compose.yml': No space left on device
rm: cannot remove 'conf-storage/.git/HEAD': No space left on device
...
```

CephFS shows 32.7% used with 60.6 TB available. The error occurs on `rm` (file deletion), not on writes.

## Root Cause

`mds_bal_fragment_size_max` was set to **10,000** (10x lower than the default of **100,000**), which matches `mds_bal_split_size`. This removes the buffer between directory fragment splitting and the ENOSPC rejection threshold, causing file deletions to fail during bursts.

### Mechanism

When a file is deleted in CephFS, the MDS creates a "stray" dentry (effectively moving the file to trash before purging). The code path is:

1. `Server::handle_client_unlink()` → `prepare_stray_dentry()` (`Server.cc:3435`)
2. `prepare_stray_dentry()` calls `check_fragment_space(mdr, straydir)` (`Server.cc:3447-3448`)
3. `check_fragment_space()` compares the stray directory fragment size against `mds_bal_fragment_size_max` (`Server.cc:3403-3416`):

```cpp
bool Server::check_fragment_space(const MDRequestRef& mdr, CDir *dir)
{
  const auto size = dir->get_frag_size();
  const auto max = bal_fragment_size_max;
  if (size >= max) {
    respond_to_request(mdr, -ENOSPC);  // <-- "No space left on device"
    return false;
  }
  return true;
}
```

If the stray directory fragment has reached the max size and splitting hasn't completed yet, the `rm` operation fails with `-ENOSPC`.

### Why This Config Causes the Problem

| Setting | Default | Our Value | Effect |
|---|---|---|---|
| `mds_bal_split_size` | 10,000 | 10,000 | Fragment scheduled for splitting at 10,000 entries |
| `mds_bal_fragment_size_max` | **100,000** | **10,000** | ENOSPC at 10,000 entries |

With defaults, there is a **10x buffer** (split at 10k, ENOSPC at 100k) for auto-splitting to complete before hitting the limit. With our config, the split trigger and ENOSPC trigger are at the **same value** — any file deletion burst before splitting finishes fails immediately.

This is confirmed by the [SUSE KB](https://www.suse.com/support/kb/doc/?id=000020569) which documents the exact same symptom pattern (ENOSPC on `rm` with plenty of space) caused by stray directory fragments hitting the limit.

## Evidence

### 1. Misconfigured `mds_bal_fragment_size_max`

```
$ ceph config dump | grep fragment_size_max
mds  advanced  mds_bal_fragment_size_max  10000    # Should be 100000
```

This was set explicitly via `ceph config set mds mds_bal_fragment_size_max 10000`. It is NOT in the Rook Helm values or set by Rook (confirmed: no matches in Rook source).

### 2. MDS Cache Configuration Mismatch

```
$ ceph config dump | grep mds_cache_memory_limit
mds          basic  mds_cache_memory_limit  51539607552    # ~48 GiB (base)
mds.cephfs-* basic  mds_cache_memory_limit  103079215104   # ~96 GiB (per-daemon override)
```

The per-MDS cache memory limit is ~96 GiB (Rook sets this to ~50% of the 192 GiB pod memory limit). This is a large cache that can accumulate many stray entries, making it easier for stray directory fragments to grow.

The [SUSE KB](https://www.suse.com/support/kb/doc/?id=000020569) notes: *"There is a correlation between `mds_cache_memory_limit` and `mds_bal_fragment_size_max` settings. When increasing `mds_cache_memory_limit`, `mds_bal_fragment_size_max` should also be increased."*

### 3. Current Stray Counts (Approaching Limit)

```
Rank 0 (cephfs-f): num_strays =     4,998   strays_created =     245,302
Rank 1 (cephfs-b): num_strays =     1,976   strays_created =      53,586
Rank 2 (cephfs-c): num_strays =    72,464   strays_created = 13,299,180
```

Rank 2 has significantly higher stray activity (13.3M strays created) with 72,464 currently in-flight. With `fragment_size_max = 10,000`, stray directories need to be split into many small fragments. Under burst conditions, individual fragments can hit the 10,000 entry limit before splitting completes.

### 4. Active Health Warnings

```
HEALTH_WARN
  1 clients failing to respond to cache pressure
    mds.cephfs-b: Client a700.clusters.zjusct.io:home failing to respond
    to cache pressure client_id: 23166360
  1 OSD(s) experiencing slow operations in BlueStore
  1 daemons have recently crashed
    mds.cephfs-a crashed on host m601 at 2026-04-03T02:57:15.050724Z
```

The MDS crash was a journal trim assertion failure (`journal.cc:213: FAILED ceph_assert(ls != this)`) on the `mds-log-trim` thread.

### 5. Config that Worsens the Situation

From `rook-ceph-cluster-v1.19.1.yaml`:
```yaml
configOverride: |
  [global]
  mds_session_blocklist_on_timeout = false
  mds_session_blocklist_on_evict = false
```

These settings prevent the MDS from forcefully reclaiming resources from unresponsive clients, contributing to sustained cache pressure.

## Source Code References

- **ENOSPC check**: `src/mds/Server.cc:3403-3416` (`check_fragment_space()`)
- **Stray dentry creation**: `src/mds/Server.cc:3435-3449` (`prepare_stray_dentry()`)
- **Config definition**: `src/common/options/mds.yaml.in:773-782` (`mds_bal_fragment_size_max`, default 100000)
- **Cache pressure health check**: `src/mds/Beacon.cc:374-424` (MDS_HEALTH_CLIENT_RECALL)

## Recommended Fix

### Immediate (runtime, no restart needed)

```bash
# Restore to default value
kubectl exec -n rook-ceph rook-ceph-tools -- ceph config set mds mds_bal_fragment_size_max 100000

# Verify
kubectl exec -n rook-ceph rook-ceph-tools -- ceph config get mds mds_bal_fragment_size_max
```

This takes effect immediately on all MDS daemons without restart (confirmed: `can_update_at_runtime: true`).

### Persistent

Add to the Helm values `configOverride` to survive cluster redeployments:

```yaml
configOverride: |
  [global]
  mon_allow_pool_delete = true
  osd_pool_default_size = 2
  osd_pool_default_min_size = 1
  auth_allow_insecure_global_id_reclaim = false
  mds_session_blocklist_on_timeout = false
  mds_session_blocklist_on_evict = false

  [mds]
  mds_bal_fragment_size_max = 100000
```

### Post-Fix Verification

```bash
# Monitor stray counts on each rank
for rank in cephfs-f cephfs-b cephfs-c; do
  echo "=== $rank ==="
  kubectl exec -n rook-ceph rook-ceph-tools -- \
    ceph tell mds.$rank perf dump mds_cache | grep num_strays
done

# Verify no ENOSPC on test deletion
# (requires temporarily raising MDS debug level to 10 to see the log messages)
kubectl exec -n rook-ceph rook-ceph-tools -- \
  ceph tell mds.* config set debug_mds 10/5
```

### Consideration for High-Churn Workloads

If file churn remains high after the fix (rank 2 has 13.3M stray creations), consider increasing beyond default:

```bash
ceph config set mds mds_bal_fragment_size_max 200000
```

Also evaluate whether `mds_session_blocklist_on_timeout = false` is still needed — re-enabling it would allow the MDS to reclaim resources from stuck clients more aggressively.
