# CephFS Client Incident: NIC TX Queue Hang → MDS Client Blocklist

**Date:** 2026-02-19
**Cluster:** Rook-Ceph v1.19.1, Ceph 19.2.3 (Squid)
**Affected host:** HPC login node (ens44f0np0, Intel XL710, i40e driver)
**Affected users:** hy, peter, sunshine, yihao, youao

---

## Summary

A hardware TX queue lockup on the Intel XL710 NIC caused ~4 minutes of complete network loss. During this window, the CephFS MDS servers exhausted their reconnect timeout and evicted all active clients. When the network recovered, the clients were blocklisted by the MDS and could no longer communicate with it. The affected home directory mounts became inaccessible (`d?????????`), with processes blocked in uninterruptible D state inside `ceph_write_begin`.

---

## Root Cause

### Network Hardware Failure

The Intel XL710 NIC (`ens44f0np0`, i40e driver) suffered a TX queue lockup:

```
[28481.075827] i40e 0000:a1:00.0 ens44f0np0: NETDEV WATCHDOG: CPU: 214: transmit queue 22 timed out 5376 ms
[28481.200615] i40e 0000:a1:00.0 ens44f0np0: tx_timeout: VSI_seid: 390, Q 22, NTC: 0x47, HWB: 0x47, NTU: 0x30, TAIL: 0x0, INT: 0x1
[28481.200622] i40e 0000:a1:00.0 ens44f0np0: tx_timeout recovery level 1, txqueue 22
```

The driver performed an automatic level-1 recovery (SW DCB reinit), which restored connectivity but only after approximately **4 minutes** of total outage.

### Failure Chain

| Kernel timestamp | Event |
|---|---|
| ~28234s | All three Ceph monitor sessions lost: `session lost, hunting for new mon` |
| 28247–28480s | All reconnect attempts fail: `socket closed (con state V1_BANNER)` — TCP connection dropped immediately after banner exchange |
| ~28481s | NIC watchdog fires; i40e level-1 TX queue reset; SW DCB reinit succeeds |
| ~28481s | Monitor sessions re-established (mon0, mon1) |
| ~28482s | Several MDS clients briefly renew caps |
| 28495–28511s | MDS reconnect window expired; MDS evicts clients: `mds0 hung` → `reconnect denied` → `session blocklisted` |

The CephFS MDS has a reconnect grace period (default 45 seconds). Because the network was down for ~4 minutes, the grace period expired on the server side. On reconnect, every affected client received:

```
ceph: mds0 reconnect denied
ceph: mds0 session blocklisted
ceph: mds1 session blocklisted
```

### Resulting Symptom

Blocklisted clients can no longer query the MDS for inode metadata. The VFS layer cannot resolve permissions, causing the mount point to show `d?????????`:

```
d?????????  ? ?       ?          ?            ? hy
d?????????  ? ?       ?          ?            ? peter
d?????????  ? ?       ?          ?            ? sunshine
d?????????  ? ?       ?          ?            ? yihao
d?????????  ? ?       ?          ?            ? youao
```

Access attempts returned `Permission denied`. Any process that had an open write on the affected mounts entered uninterruptible D state, blocked inside `ceph_write_begin` → `netfs_write_begin` → `folio_wait_bit_common` (waiting for a page bit that the blocklisted client can never clear).

### Additional Hardware Note

The BERT log at boot recorded a Machine Check Exception from the **previous boot** — a CPU L1 cache data read error on SOCKET 1 (APIC 0x189). This is unrelated to the CephFS incident but indicates pre-existing hardware instability on this host that warrants investigation.

---

## Affected Mounts

All five affected home directories were CephFS subvolumes mounted by autofs (`/home` autofs, timeout=300s):

| Mount point | CephFS path |
|---|---|
| `/home/hy` | `/volumes/home/hy/27ee2d0f-...` |
| `/home/peter` | `/volumes/home/peter/9ce28e68-...` |
| `/home/sunshine` | `/volumes/home/sunshine/1f434fc2-...` |
| `/home/yihao` | `/volumes/home/yihao/308679c6-...` |
| `/home/youao` | `/volumes/home/youao/673982b0-...` |

`/home/bowling` and `/pool/nvme` were also mounted but recovered successfully (likely remounted via autofs after the outage window, obtaining fresh non-blocklisted client IDs).

---

## Recovery Procedure

### 1. Kill processes with open files on broken mounts

```bash
sudo fuser -km /home/hy /home/peter /home/sunshine /home/yihao /home/youao
```

Processes in D state cannot be killed by signal. The lazy unmount in the next step will detach the mountpoint, after which the blocked page wait will return EIO and unblock them.

### 2. Force unmount all broken mounts

```bash
sudo umount -f -l /home/hy /home/peter /home/sunshine /home/yihao /home/youao
```

- `-f`: force unmount (required for unresponsive network filesystem)
- `-l`: lazy detach from namespace (required if processes still hold fds open)

### 3. Clear the blocklist on the Ceph cluster

Old blocklist entries persist in the OSD map. New autofs mounts receive fresh client IDs and are not blocked, but cleanup prevents OSD map bloat:

```bash
ceph osd blocklist ls    # inspect current entries
ceph osd blocklist clear # remove all
```

### 4. Verify recovery

Autofs remounts on first access:

```bash
ls /home/hy /home/peter /home/sunshine /home/yihao /home/youao
```

---

## Follow-up Actions

1. **NIC firmware/driver update**: Investigate the i40e TX queue hang. Check current driver and firmware version (`ethtool -i ens44f0np0`) and apply available updates for the XL710.
2. **Network redundancy**: A single NIC failure caused a 4-minute total outage and MDS client eviction. Consider bonding/LACP to avoid single points of failure on the network path to the Ceph cluster.
3. **MDS reconnect timeout tuning**: The default MDS reconnect grace period is 45 seconds. If transient longer outages are expected, it can be extended:
   ```bash
   ceph config set mds mds_reconnect_timeout <seconds>
   ```
   Note: this delays MDS recovery after a genuine client failure.
4. **CPU MCE investigation**: The BERT record from the previous boot (L1 cache error, SOCKET 1, APIC 0x189) should be analyzed with `mcelog` or `rasdaemon` to determine if the CPU/DIMM requires replacement.
