# Rook Ceph OSD ID 识别错误问题分析报告

## 1. 问题现场还原与分析

### 1.1 问题现象

在 commit `e0bb2cea151100e1538427a8728d49b3804a8a59` 中修改 Ceph Pod 资源限制后，29 个 OSD 被自动重新部署，其中 OSD 13 发生了设备识别错误。

### 1.2 日志分析

从 OSD 13 Pod 的 `activate` init 容器日志中可以看到：

```
+ OSD_ID=13
+ DEVICE=/dev/nvme1n1
+ ceph-volume raw list /dev/nvme1n1
{
    "b87af9f9-05e9-450f-b8c4-b9a902ccc00a": {
        "ceph_fsid": "356ad2aa-0c04-452f-a0e7-ded4c0a5899b",
        "device": "/dev/nvme1n1",
        "osd_id": 2,
        "osd_uuid": "b87af9f9-05e9-450f-b8c4-b9a902ccc00a",
        "type": "bluestore"
    }
}
+ find_device
no disk found with OSD ID 13
+ ceph-volume raw list
{
    "1af3844d-1985-4e87-9ca9-8e6f1013aff9": {
        "device_db": "/dev/mapper/ceph--fe023b8b--bc1e--4d09--a6f3--5fc84ba7fd4f-osd--db--7fbce099--f501--4cd0--bdd1--5842f87dbd22",
        "osd_uuid": "1af3844d-1985-4e87-9ca9-8e6f1013aff9"
    },
    "46b9e094-5f47-4620-a417-d48cfcfb0d21": {
        "ceph_fsid": "356ad2aa-0c04-452f-a0e7-ded4c0a5899b",
        "device": "/dev/nvme2n1",
        "osd_id": 13,
        "osd_uuid": "46b9e094-5f47-4620-a417-d48cfcfb0d21",
        "type": "bluestore"
    },
    ...
}
Traceback (most recent call last):
  File "<string>", line 4, in <module>
KeyError: 'osd_id'
```

### 1.3 问题总结

1. **OSD 13 被错误分配设备**：OSD 13 的 Pod 配置中，`ROOK_BLOCK_PATH` 环境变量被错误地设置为 `/dev/nvme1n1`，而该设备实际上属于 OSD 2。

2. **第一次查找失败**：在 `/dev/nvme1n1` 上执行 `ceph-volume raw list` 时，返回的是 OSD 2 的信息，找不到 OSD 13。

3. **第二次查找崩溃**：当尝试扫描所有设备时，`ceph-volume raw list` 返回了一些只有 `device_db` 字段而没有 `osd_id` 字段的设备信息，导致 `find_device` 函数在尝试访问 `info['osd_id']` 时抛出 `KeyError`。

## 2. Rook Ceph 源码分析

### 2.1 关键代码位置

问题代码位于 `/home/bowling/argo-cd.clusters.zjusct.io/tmp/rook/pkg/operator/ceph/cluster/osd/spec.go` 中的 `activateOSDOnNodeCode` 变量（第 102-204 行）。

### 2.2 find_device 函数分析

```bash
function find_device() {
    python3 -c "
import sys, json
for _, info in json.load(sys.stdin).items():
    if info['osd_id'] == $OSD_ID:
        print(info['device'], end='')
        print('found device: ' + info['device'], file=sys.stderr)
        sys.exit(0)
sys.exit('no disk found with OSD ID $OSD_ID')
"
}
```

### 2.3 问题根源

该函数存在两个问题：

1. **没有检查字段存在性**：直接访问 `info['osd_id']` 和 `info['device']`，而没有检查这些字段是否存在。

2. **没有处理不完整的设备信息**：从日志中可以看到，`ceph-volume raw list` 可能返回一些只有 `device_db` 或 `device_wal` 字段而没有 `osd_id` 字段的条目。

## 3. 修复方案

### 3.1 修复 find_device 函数

修改 `spec.go` 中的 `activateOSDOnNodeCode` 变量，使 `find_device` 函数更加健壮：

```bash
function find_device() {
    python3 -c "
import sys, json
for _, info in json.load(sys.stdin).items():
    if 'osd_id' in info and 'device' in info and info['osd_id'] == $OSD_ID:
        print(info['device'], end='')
        print('found device: ' + info['device'], file=sys.stderr)
        sys.exit(0)
sys.exit('no disk found with OSD ID $OSD_ID')
"
}
```

### 3.2 修复说明

1. **添加字段存在性检查**：在访问 `info['osd_id']` 和 `info['device']` 之前，先使用 `'osd_id' in info` 和 `'device' in info` 检查这些字段是否存在。

2. **跳过不完整的条目**：对于没有 `osd_id` 或 `device` 字段的条目，直接跳过，继续处理下一个条目。

### 3.3 额外建议

除了修复 `find_device` 函数外，还应该调查为什么 OSD 13 会被错误地分配 OSD 2 的设备路径。这可能涉及到 OSD 准备阶段的设备映射逻辑。

## 4. 总结

本问题的根本原因是 `find_device` 函数在处理 `ceph-volume raw list` 的输出时，没有检查字段的存在性，导致遇到不完整的设备信息时抛出 `KeyError` 异常。通过添加字段存在性检查，可以使代码更加健壮，能够正确处理各种可能的输入情况。

---

**报告生成时间**：2026-03-04  
**分析工具**：Doubao Seed 2.0 Code  
**Co-authored-by**：Doubao Seed 2.0 Code <noreply@doubao.com>
