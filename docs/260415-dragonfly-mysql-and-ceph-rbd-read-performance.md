# Ceph RBD Random Read Performance Investigation

Date: 2026-04-15

## Problem

Random 4K read on Ceph RBD PVC (`ceph-block` StorageClass) is abnormally slow: **231 IOPS**, while random 4K write is **58.2K IOPS** — a 250x asymmetry. Sequential I/O is reasonable (162-278 MiB/s).

This was discovered during a Dragonfly MySQL recovery attempt: MySQL initialization on a fresh Ceph RBD PVC took >10 minutes due to random I/O during `mysqld --initialize-insecure`, exceeding the default startup probe timeout.

## Benchmark Results (on `storage` node, `ceph-block` StorageClass)

| Test | Throughput | IOPS | p50 Latency |
|------|-----------|------|-------------|
| Sequential Write 1M | 162 MiB/s | 162 | 0.56 ms |
| Sequential Read 1M | 278 MiB/s | 278 | 0.34 ms |
| Random Write 4K | 227 MiB/s | 58.2K | 3 us |
| **Random Read 4K** | **927 KiB/s** | **231** | **0.96 ms** |
| Random RW 4K (70R/30W) | R: 1.4 MiB/s / W: 588 KiB/s | R: 344 / W: 147 | R: 0.83 ms |
| Local disk RW 4K (70R/30W) | R: 33.7 MiB/s / W: 14.5 MiB/s | R: 8,630 / W: 3,706 | R: 0.11 ms |

## Investigation

### Cluster State

```
HEALTH_WARN
  1 OSD(s) experiencing slow operations in BlueStore (osd.12, m600, NVMe)
  1 clients failing to respond to cache pressure (MDS client)
  1 daemons have recently crashed (osd.12)
```

The cluster is otherwise healthy: 29/29 OSDs up, 1359/1370 PGs active+clean, 11 TiB / 90 TiB used.

### OSD Topology (`storage` node)

The `storage` node hosts **8 HDD OSDs** and **1 SSD OSD**, all with `bluefs_single_shared_device: 1`:

| OSD | Disk | Size | Class | WAL/DB |
|-----|------|------|-------|--------|
| 6 | sda | 4 TB | hdd | Shared (same disk) |
| 15 | sdc | 4 TB | hdd | Shared (same disk) |
| 16 | sdb | 4 TB | hdd | Shared (same disk) |
| 17 | sdd | 4 TB | hdd | Shared (same disk) |
| 23 | sde | 8 TB | hdd | Shared (same disk) |
| 24 | sdg | 8 TB | hdd | Shared (same disk) |
| 25 | sdh | 8 TB | hdd | Shared (same disk) |
| 26 | sdf | 8 TB | hdd | Shared (same disk) |
| 27 | sdj | 1 TB | ssd | Shared (same disk) |

### CRUSH Rule and PG Placement

The `ceph-blockpool` uses CRUSH rule `ceph-blockpool_osd` with `size: 2`. The rule selects from all OSDs in the cluster uniformly (`choose_firstn` from `root default`). PG mapping shows many PGs with **both replicas on HDD OSDs** on the storage node:

```
PG 15.0: acting [26, 25]   -> both HDD on storage
PG 15.6: acting [16, 15]   -> both HDD on storage
PG 15.7: acting [24, 15]   -> both HDD on storage
PG 15.b: acting [24, 16]   -> both HDD on storage
```

### RBD Image Configuration

- Features: `layering` only (no deep-flatten, exclusive-lock)
- Object size: 4 MiB (order 22)
- Client cache mode: `write through` (no read caching)

## Root Cause Analysis

**Primary cause: HDD OSDs with shared WAL/DB serving random reads**

1. **BlueStore shared device**: All 8 HDD OSDs on `storage` have WAL, RocksDB (DB), and data on the same spinning disk. Random reads must compete with sequential WAL journaling and RocksDB compaction for physical disk head time.

2. **HDD IOPS ceiling**: Typical HDD random 4K IOPS is ~100-200. With WAL/DB contention, the effective read IOPS drops further. The observed 231 IOPS is consistent with this.

3. **Write asymmetry explained**: BlueStore's WAL absorbs writes sequentially (even on HDD). The `bluestore_cache_size_hdd = 4GB` also batches writes effectively. Additionally, many PGs have one replica on NVMe OSDs (m600/m601), so write acknowledgments can return from the faster path.

4. **Client-side cache disabled**: RBD `write through` mode means no client read caching. Every read goes directly to OSDs.

## Impact

- Any database or latency-sensitive workload on `ceph-block` PVCs scheduled on `storage` will experience poor random read performance
- The issue affects all 8 HDD OSDs on `storage` equally

## Recommendations

### Short-term

1. **Schedule latency-sensitive workloads on m600/m601** where NVMe/SSD OSDs are available, using node affinity or pod topology spread

### Long-term

1. **Dedicated WAL/DB device for HDD OSDs**: Add a small SSD (even 100GB) as WAL+DB device for the 8 HDD OSDs on `storage`. This is the single most impactful change — it frees the disk head for data reads while WAL/DB operations run on SSD. Reference: [BlueStore WAL/DB configuration](https://docs.ceph.com/en/latest/rados/configuration/bluestore-config-ref/)

   ```bash
   ceph-bluestore-tool --set-db /dev/sdX --path /var/lib/ceph/osd/ceph-<id>
   ```

2. **CRUSH rule targeting NVMe/SSD for ceph-blockpool**: Create a separate CRUSH rule or use `primary-affinity` to prefer NVMe/SSD OSDs for the block pool. Alternatively, create a new pool backed only by NVMe/SSD OSDs for latency-sensitive workloads.

3. **Enable RBD client-side read cache**: For workloads that tolerate potentially stale reads, enabling the RBD read cache can significantly reduce read latency:

   ```bash
   rbd feature enable <pool>/<image> object-map,fast-diff
   rbd cache enable <pool>/<image>
   ```

4. **Consider `fast_read` on the pool**: For replicated pools, setting `fast_read = 1` allows reads from any replica (not just the primary), which can help if replicas are distributed across heterogeneous OSD types.

   ```bash
   ceph osd pool set ceph-blockpool fast_read 1
   ```

## Appendix: Investigation Commands

```bash
# Ceph cluster health
kubectl exec -n rook-ceph <tools-pod> -- ceph status
kubectl exec -n rook-ceph <tools-pod> -- ceph health detail

# OSD performance
kubectl exec -n rook-ceph <tools-pod> -- ceph osd perf

# OSD block device layout
kubectl exec -n rook-ceph <tools-pod> -- ceph osd metadata <osd-id> | jq '{class: .default_device_class, type: .bluestore_bdev_type, device: .bluestore_bdev_devices, shared: .bluefs_single_shared_device}'

# Pool configuration
kubectl exec -n rook-ceph <tools-pod> -- ceph osd pool get ceph-blockpool all

# PG placement
kubectl exec -n rook-ceph <tools-pod> -- ceph pg ls-by-pool ceph-blockpool | head -20

# RBD image info
kubectl exec -n rook-ceph <tools-pod> -- rbd info ceph-blockpool/<image-name>

# RBD cache mode (from privileged pod on the node)
cat /sys/block/rbd0/queue/write_cache  # shows "write through" or "write back"

# CRUSH rule
kubectl exec -n rook-ceph <tools-pod> -- ceph osd crush rule dump ceph-blockpool_osd

# fio benchmark (single-thread, synchronous)
fio --name=rand-read --rw=randread --bs=4K --size=512M --iodepth=1 --directory=/data
fio --name=rand-write --rw=randwrite --bs=4K --size=512M --iodepth=1 --end_fsync=1 --directory=/data
```

## MySQL E2E Benchmark on Ceph RBD (`storage` node)

Test: Bitnami MySQL 8.0.36, 10 tables x 10K rows, 60s runs

| Test | Threads | TPS | QPS | Avg Latency | P95 Latency |
|------|---------|-----|-----|-------------|-------------|
| **OLTP Read-Write** | 4 | 12.7 | 255 | 313 ms | 646 ms |
| **OLTP Read-Only** | 4 | **1,218** | **19,480** | 3.3 ms | 4.0 ms |
| **OLTP Write-Only** | 4 | 13.3 | 80 | 300 ms | 635 ms |
| **OLTP Read-Write** | 1 | 6.9 | 138 | 145 ms | 502 ms |

### Key observations

- **Read-only workloads are fine** — 19.5K QPS, 4ms p95. MySQL's buffer pool caches hot data effectively, so the poor random read I/O from fio doesn't matter for reads.
- **Write workloads are very slow** — ~13 TPS at 4 threads, p95 latency 600-800ms. This matches the fio result: random writes are fine at the storage level, but MySQL's InnoDB `fsync`/`doublewrite` and transaction logging turns each write into many small fsync calls that hit the Ceph RBD latency.
- **The initialization slowness is likely the write-heavy data dictionary creation phase**, not random reads as I initially assumed from the fio benchmark. InnoDB doublewrite buffer and redo log flushes are the bottleneck.
- **For dragonfly's workload** (manager metadata, not heavy writes), this performance is probably adequate — the manager doesn't do heavy OLTP writes, just config/task tracking.
