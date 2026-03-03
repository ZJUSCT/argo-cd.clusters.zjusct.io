# Rook Ceph OSD ID 识别错误问题分析报告

**作者**: Qwen-Coder  
**日期**: 2026-03-04  
**问题**: OSD ID 与设备绑定错误导致 OSD 13 无法启动

---

## 1. 问题现场还原

### 1.1 问题触发

在提交 `e0bb2ce` 中，我们更改了 Ceph OSD Pod 的资源限制，导致 29 个 OSD 被 Rook Ceph Operator 自动重新部署。在重新部署过程中，发生了 OSD ID 与设备绑定错误的问题。

### 1.2 当前状态

通过 `kubectl get pods -n rook-ceph -l app=rook-ceph-osd -o wide` 观察到：

```
rook-ceph-osd-13-764c99fc5d-mwwq5   0/2   Init:CrashLoopBackOff   11 (4m48s ago)   43m   172.25.4.60   m600
rook-ceph-osd-2-5fd58f57fc-xx68n    2/2   Running                 0                43m   172.25.4.60   m600
```

OSD 13 处于 `Init:CrashLoopBackOff` 状态，OSD 2 正常运行。

### 1.3 错误日志分析

从 OSD 13 的 `activate` init container 日志中可以看到：

```bash
+ OSD_ID=13
+ OSD_UUID=46b9e094-5f47-4620-a417-d48cfcfb0d21
+ DEVICE=/dev/nvme1n1  # ← 错误的设备路径
+ ceph-volume raw list /dev/nvme1n1
{
    "b87af9f9-05e9-450f-b8c4-b9a902ccc00a": {
        "ceph_fsid": "356ad2aa-0c04-452f-a0e7-ded4c0a5899b",
        "device": "/dev/nvme1n1",
        "osd_id": 2,  # ← 该设备实际上属于 OSD 2
        "osd_uuid": "b87af9f9-05e9-450f-b8c4-b9a902ccc00a",
        "type": "bluestore"
    }
}
```

当 OSD 13 尝试在所有设备中查找自己的 OSD ID 时：

```bash
+ ceph-volume raw list  # 列出所有设备
{
    "46b9e094-5f47-4620-a417-d48cfcfb0d21": {
        "ceph_fsid": "356ad2aa-0c04-452f-a0e7-ded4c0a5899b",
        "device": "/dev/nvme2n1",  # ← OSD 13 实际应该使用的设备
        "osd_id": 13,
        "osd_uuid": "46b9e094-5f47-4620-a417-d48cfcfb0d21",
        "type": "bluestore"
    },
    "b87af9f9-05e9-450f-b8c4-b9a902ccc00a": {
        "ceph_fsid": "356ad2aa-0c04-452f-a0e7-ded4c0a5899b",
        "device": "/dev/nvme1n1",
        "osd_id": 2,
        "osd_uuid": "b87af9f9-05e9-450f-b8c4-b9a902ccc00a",
        "type": "bluestore"
    },
    ...
}
```

**关键发现**：
- OSD 13 的 Deployment 中 `ROOK_BLOCK_PATH` 环境变量被错误设置为 `/dev/nvme1n1`
- OSD 13 实际应该使用 `/dev/nvme2n1`
- OSD 2 正确使用 `/dev/nvme1n1`

### 1.4 Deployment 配置对比

```yaml
# OSD 13 Deployment
env:
  - name: ROOK_OSD_ID
    value: "13"
  - name: ROOK_BLOCK_PATH
    value: /dev/nvme1n1  # 错误！应该是 /dev/nvme2n1

# OSD 2 Deployment
env:
  - name: ROOK_OSD_ID
    value: "2"
  - name: ROOK_BLOCK_PATH
    value: /dev/nvme1n1  # 正确
```

---

## 2. Rook Ceph 源码分析

### 2.1 OSD ID 和设备绑定的数据流

#### 2.1.1 数据结构定义

在 `pkg/operator/ceph/cluster/osd/osd.go:113` 定义了 `OSDInfo` 结构：

```go
type OSDInfo struct {
    ID             int    `json:"id"`
    Cluster        string `json:"cluster"`
    UUID           string `json:"uuid"`
    DevicePartUUID string `json:"device-part-uuid"`
    DeviceClass    string `json:"device-class"`
    // BlockPath is the logical Volume path for an OSD created by Ceph-volume
    BlockPath     string `json:"lv-path"`
    // ... 其他字段
}
```

#### 2.1.2 OSD 准备流程

1. **Prepare Job 执行** (`create.go:266-358`)
   - `startProvisioningOverNodes()` 为每个节点创建 OSD prepare job
   - prepare job 使用 `ceph-volume raw list` 扫描节点上的设备
   - 结果写入状态 ConfigMap

2. **创建 OSD Deployment** (`create.go:410-437`)
   - `createDaemonOnNode()` 调用 `deploymentOnNode()`
   - 从 `OSDInfo` 结构体读取 `BlockPath` 字段
   - 设置 Deployment 的 `ROOK_BLOCK_PATH` 环境变量

3. **OSD 激活流程** (`spec.go:160-206`)
   - activate init container 使用 `ROOK_BLOCK_PATH` 作为初始设备
   - 通过 `ceph-volume raw list $DEVICE` 验证设备
   - 如果设备不正确，扫描所有设备查找匹配的 OSD ID

### 2.2 问题代码路径

#### 2.2.1 OSD ID 分配（ceph-volume）

`ceph-volume raw list` 命令读取磁盘上的 OSD 元数据（存储在磁盘的 LVM 标签或文件系统元数据中），返回：

```json
{
    "<osd_uuid>": {
        "ceph_fsid": "<cluster_fsid>",
        "device": "/dev/nvme1n1",
        "osd_id": 2,
        "osd_uuid": "<uuid>",
        "type": "bluestore"
    }
}
```

**关键点**：OSD ID 是在 OSD 初次创建时由 Ceph 分配的，并持久化存储在磁盘上。

#### 2.2.2 Rook 读取 OSD 信息

在 `pkg/daemon/ceph/osd/volume.go` 中，`configureCVDevices()` 函数：

1. 执行 `ceph-volume raw list --format json`
2. 解析输出，构建 `OSDInfo` 列表
3. 将结果写入状态 ConfigMap

#### 2.2.3 Deployment 环境变量设置

在 `pkg/operator/ceph/cluster/osd/spec.go` 和 `envs.go` 中：

```go
// envs.go:45
blockPathVarName = "ROOK_BLOCK_PATH"

// osd.go:731-732
if envVar.Name == "ROOK_BLOCK_PATH" || envVar.Name == "ROOK_LV_PATH" {
    osd.BlockPath = envVar.Value
}
```

### 2.3 问题根源分析

**根本原因**：在 e0bb2ce 提交更改资源限制后，Rook Operator 重新创建了 OSD Deployment，但在重建过程中，`ROOK_BLOCK_PATH` 环境变量的值可能被错误地传递或缓存。

**可能的问题场景**：

1. **场景 A - ConfigMap 缓存问题**
   - OSD prepare job 完成后将结果写入 ConfigMap
   - Operator 读取 ConfigMap 时可能读取了过期的数据
   - 导致 OSD 13 的 Deployment 使用了错误的 BlockPath

2. **场景 B - 设备扫描顺序问题**
   - 系统重启或重新扫描后，设备名称 `/dev/nvmeXn1` 的顺序可能发生变化
   - `ceph-volume raw list` 的输出顺序不确定
   - 在匹配 OSD ID 和设备时可能出现混淆

3. **场景 C - Rook Operator 状态管理问题**
   - Rook Operator 可能在 reconcile 过程中保留了旧的 OSDInfo 缓存
   - 创建新 Deployment 时使用了缓存的旧数据

**最可能的原因**：

通过分析日志和代码，问题最可能出现在 **OSD prepare job 执行期间，设备扫描和 OSD ID 匹配的竞态条件**。

当 OSD prepare pod 在节点上运行时：
1. 它扫描所有设备并调用 `ceph-volume raw list`
2. 根据扫描结果构建 `OSDInfo` 列表
3. 如果在扫描过程中设备状态发生变化（如其他 OSD 正在重启），可能导致元数据读取错误

---

## 3. 修复方案

### 3.1 立即修复措施（临时方案）

**方案 1：手动修正 Deployment**

```bash
# 获取当前 OSD 13 的 Deployment
kubectl get deployment rook-ceph-osd-13 -n rook-ceph -o yaml > osd-13-deployment.yaml

# 编辑文件，将 ROOK_BLOCK_PATH 从 /dev/nvme1n1 改为 /dev/nvme2n1
# 然后应用更改
kubectl apply -f osd-13-deployment.yaml

# 删除 Pod 让它重新创建
kubectl delete pod rook-ceph-osd-13-764c99fc5d-mwwq5 -n rook-ceph
```

**方案 2：触发 Rook Operator 重新同步**

```bash
# 删除 OSD 13 的 Deployment，让 Operator 重新创建
kubectl delete deployment rook-ceph-osd-13 -n rook-ceph

# 如果问题仍然存在，可能需要重启 Rook Operator
kubectl rollout restart deployment rook-ceph-operator -n rook-ceph
```

### 3.2 长期修复方案（代码层面）

#### 3.2.1 修复 1：增强设备验证逻辑

**文件**: `pkg/operator/ceph/cluster/osd/spec.go`

在 activate init container 中，当前代码已经有设备验证逻辑，但可以增强：

```bash
# 当前逻辑（第 181-192 行）
if ! ceph-volume raw list "$DEVICE" > "$OSD_LIST"; then
    # if the command fails, the disk may be renamed
    echo '' > "$OSD_LIST"
fi
cat "$OSD_LIST"

if ! find_device < "$OSD_LIST"; then
    ceph-volume raw list > "$OSD_LIST"
    cat "$OSD_LIST"
    DEVICE="$(find_device < "$OSD_LIST")"
fi
```

**问题**：当 `ceph-volume raw list "$DEVICE"` 成功执行但返回的 `osd_id` 不匹配时，代码不会进入 fallback 逻辑。

**修复建议**：

```bash
# 修改为：即使命令成功，也要检查 OSD ID 是否匹配
if ! ceph-volume raw list "$DEVICE" > "$OSD_LIST"; then
    echo '' > "$OSD_LIST"
fi

# 检查找到的 OSD ID 是否匹配
if ! find_device < "$OSD_LIST"; then
    # OSD ID 不匹配或设备不存在，扫描所有设备
    ceph-volume raw list > "$OSD_LIST"
    DEVICE="$(find_device < "$OSD_LIST")"
fi

[[ -z "$DEVICE" ]] && { echo "no device" ; exit 1 ; }
```

#### 3.2.2 修复 2：使用 UUID 而非设备路径

**文件**: `pkg/operator/ceph/cluster/osd/osd.go` 和 `envs.go`

当前使用设备路径（如 `/dev/nvme1n1`），但设备路径在重启后可能变化。建议使用 `/dev/disk/by-id/` 或 `/dev/disk/by-uuid/` 路径。

**代码修改**：

```go
// 在创建 OSDInfo 时，优先使用持久化设备标识
func getStableDevicePath(device string) string {
    // 尝试查找 /dev/disk/by-id/ 路径
    byIdPath := fmt.Sprintf("/dev/disk/by-id/%s", getDeviceID(device))
    if _, err := os.Stat(byIdPath); err == nil {
        return byIdPath
    }
    return device
}
```

#### 3.2.3 修复 3：增强 OSD prepare 和 Deployment 创建之间的数据一致性检查

**文件**: `pkg/operator/ceph/cluster/osd/create.go`

在 `createNewOSDsFromStatus()` 函数中添加验证：

```go
func (c *createConfig) createNewOSDsFromStatus(
    status *OrchestrationStatus,
    nodeOrPVCName string,
    errs *provisionErrors,
) {
    // ... 现有代码 ...

    for i, osd := range status.OSDs {
        // 新增：验证 OSD ID 和设备的绑定关系
        if err := c.validateOSDDeviceBinding(&osd); err != nil {
            errs.addError("OSD %d device binding validation failed: %v", osd.ID, err)
            continue
        }

        // ... 创建 Deployment ...
    }
}

func (c *createConfig) validateOSDDeviceBinding(osd *OSDInfo) error {
    // 执行 ceph-volume raw list <device> 验证设备上的 OSD ID 是否匹配
    // 如果不匹配，返回错误
    return nil
}
```

### 3.3 预防措施

1. **启用设备持久化命名**
   - 在 Kubernetes 节点上启用 `udev` 规则，确保设备名称一致性
   - 使用 `/dev/disk/by-id/` 路径而非 `/dev/nvmeXn1`

2. **定期备份 OSD 元数据**
   ```bash
   # 定期运行并备份
   ceph-volume raw list --format json > osd-metadata-backup.json
   ```

3. **升级 Rook 时注意**
   - 在更改资源配置前，先暂停 Rook Operator
   - 逐个重启 OSD Deployment，而不是一次性全部重启

---

## 4. 总结

### 4.1 问题原因

OSD 13 的 Deployment 中 `ROOK_BLOCK_PATH` 环境变量被错误设置为 `/dev/nvme1n1`（属于 OSD 2 的设备），而不是正确的 `/dev/nvme2n1`。这导致 OSD 13 的 activate init container 尝试在错误的设备上查找自己的 OSD ID，最终失败。

### 4.2 影响范围

- 影响：OSD 13 无法启动，导致 Ceph 集群数据可用性降低
- 根本原因：可能是 Rook Operator 在 reconcile 过程中使用了缓存的旧数据，或设备扫描时发生竞态条件

### 4.3 建议的修复优先级

1. **立即执行**：手动修正 OSD 13 Deployment 的 `ROOK_BLOCK_PATH` 环境变量
2. **短期**：重启 Rook Operator，让它自动修复状态不一致的问题
3. **长期**：在 Rook 源码中增强设备验证逻辑，使用持久化设备标识

### 4.4 后续跟进

- 监控 OSD 13 启动后的状态
- 检查其他 OSD 是否存在类似问题
- 考虑在 Rook 项目中提交 issue 或 PR 修复此问题

---

## 附录 A: 相关日志和命令输出

### A.1 OSD 13 activate init container 完整日志

```
+ OSD_ID=13
+ OSD_UUID=46b9e094-5f47-4620-a417-d48cfcfb0d21
+ OSD_STORE_FLAG=--bluestore
+ OSD_DATA_DIR=/var/lib/ceph/osd/ceph-13
+ KEYRING_FILE=/var/lib/ceph/osd/ceph-13/keyring
+ CV_MODE=raw
+ DEVICE=/dev/nvme1n1
...
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
# 完整扫描显示 OSD 13 实际在 /dev/nvme2n1
```

### A.2 相关 K8S 资源

```bash
# OSD 13 Deployment 环境变量
kubectl get deployment rook-ceph-osd-13 -n rook-ceph \
  -o jsonpath='{.spec.template.spec.containers[0].env}' | jq '.[] | select(.name=="ROOK_BLOCK_PATH" or .name=="ROOK_OSD_ID")'

# 输出:
# {
#   "name": "ROOK_OSD_ID",
#   "value": "13"
# }
# {
#   "name": "ROOK_BLOCK_PATH",
#   "value": "/dev/nvme1n1"  # 错误
# }
```

### A.3 设备信息

```bash
# m600 节点上的 NVMe 设备
/dev/nvme0n1 - OSD 4 (3.5TB Intel)
/dev/nvme1n1 - OSD 2 (2.9TB DAPUSTOR)  # 被 OSD 13 错误引用
/dev/nvme2n1 - OSD 13 (3.5TB Samsung)  # OSD 13 应该使用的设备
/dev/nvme3n1 - OSD 12 (7.0TB Intel)
```

---

*报告结束*
