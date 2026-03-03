# Rook Ceph OSD ID 识别错误问题分析报告

**作者**: Qwen-Coder  
**日期**: 2026-03-04  
**问题**: OSD ID 与设备绑定错误导致 OSD 13 无法启动

---

## 执行摘要

**根本原因**：Rook Operator 在更新现有 OSD Deployment 时，从旧 Deployment 中读取 `ROOK_BLOCK_PATH` 环境变量并传递给新 Deployment。当旧 Deployment 的 `ROOK_BLOCK_PATH` 配置错误时，会导致新 Deployment 继承这个错误配置。

**问题链路**：
1. OSD 13 的某个历史 Deployment 中 `ROOK_BLOCK_PATH` 被错误设置为 `/dev/nvme1n1`
2. e0bb2ce 提交触发 Rook Operator 重新创建 OSD Deployment
3. Rook 从旧 Deployment 读取 `ROOK_BLOCK_PATH=/dev/nvme1n1`（错误值）
4. 新创建的 OSD 13 Deployment 继承了错误的设备路径
5. OSD 13 激活时尝试在 `/dev/nvme1n1` 上查找 OSD ID 13，但该设备实际属于 OSD 2

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

#### 2.1.1 OSD 创建流程（新增 OSD）

1. **Prepare Job 执行** (`create.go:266-358`)
   - `startProvisioningOverNodes()` 为每个节点创建 OSD prepare job
   - prepare job 使用 `ceph-volume raw list` 扫描节点上的设备
   - 结果写入状态 ConfigMap，**此时 `BlockPath` 是正确的**（来自 `ceph-volume` 输出）

2. **创建 OSD Deployment** (`create.go:410-437`)
   - `createDaemonOnNode()` 调用 `deploymentOnNode()`
   - 从 `OSDInfo` 结构体读取 `BlockPath` 字段
   - 设置 Deployment 的 `ROOK_BLOCK_PATH` 环境变量

#### 2.1.2 OSD 更新流程（现有 OSD）⚠️ **问题所在**

在 `update.go:95-194` 中，当 Rook Operator 需要更新现有 OSD Deployment 时（如 e0bb2ce 提交触发资源限制变更）：

```go
// update.go:148
osdInfo, err := c.cluster.getOSDInfo(dep)
if err != nil {
    errs.addError("...")
    continue
}
c.osdDesiredState[osdID] = &osdInfo  // ← 保存从旧 Deployment 读取的 OSDInfo

// ...

// update.go:191-195
if osdIsOnPVC(dep) {
    updatedDep, err = deploymentOnPVCFunc(c.cluster, &osdInfo, nodeOrPVCName, c.provisionConfig)
    // ↑ 使用从旧 Deployment 读取的 osdInfo 创建新 Deployment
}
```

在 `osd.go:706-765` 的 `getOSDInfo()` 函数中：

```go
func (c *Cluster) getOSDInfo(d *appsv1.Deployment) (OSDInfo, error) {
    // ...
    for _, envVar := range container.Env {
        if envVar.Name == "ROOK_BLOCK_PATH" || envVar.Name == "ROOK_LV_PATH" {
            osd.BlockPath = envVar.Value  // ← 从旧 Deployment 读取 BlockPath
        }
        // ...
    }
    
    // 7.6 的 fallback 逻辑：如果非 PVC 且 BlockPath 为空，从 init container 读取
    if !isPVC && osd.BlockPath == "" {
        osd.BlockPath, err = getBlockPathFromActivateInitContainer(d)
        // ...
    }
}
```

**关键发现**：当更新现有 OSD Deployment 时，Rook **不会** 重新从 ConfigMap 或 `ceph-volume` 读取设备信息，而是直接从旧 Deployment 的环境变量中提取 `ROOK_BLOCK_PATH`。

这意味着：
- 如果旧 Deployment 的 `ROOK_BLOCK_PATH` 正确 → 新 Deployment 正确
- **如果旧 Deployment 的 `ROOK_BLOCK_PATH` 错误 → 新 Deployment 继承错误** ⚠️

### 2.2 问题根源分析

**问题场景重现**：

1. **初始状态**（假设）：
   - OSD 13 的 Deployment 被错误创建，`ROOK_BLOCK_PATH=/dev/nvme1n1`（应该是 `/dev/nvme2n1`）
   - 可能原因：OSD 初次创建时的竞态条件或 Rook Bug

2. **触发事件**（e0bb2ce 提交）：
   - Helm values 中 OSD 资源限制变更
   - Argo CD 同步配置
   - Rook Operator 检测到配置变更，开始重新创建 OSD Deployment

3. **Rook Operator 行为**：
   ```
   for each existing OSD deployment:
       osdInfo = getOSDInfo(oldDeployment)  // ← 读取 ROOK_BLOCK_PATH=/dev/nvme1n1
       newDeployment = createDeployment(osdInfo)  // ← 使用错误的 BlockPath
   ```

4. **结果**：
   - OSD 13 新 Deployment 的 `ROOK_BLOCK_PATH` 仍然是 `/dev/nvme1n1`
   - OSD 13 激活失败，因为它在错误的设备上找不到 OSD ID 13

---

## 3. 修复方案

### 3.1 立即修复措施（临时方案）

**方案 1：手动修正 Deployment（推荐）**

```bash
# 方法 A：直接编辑 Deployment
kubectl edit deployment rook-ceph-osd-13 -n rook-ceph
# 找到 ROOK_BLOCK_PATH 环境变量，将值从 /dev/nvme1n1 改为 /dev/nvme2n1

# 方法 B：使用 patch 命令
kubectl patch deployment rook-ceph-osd-13 -n rook-ceph --type='json' -p='[
  {"op": "replace", "path": "/spec/template/spec/containers/0/env/5/value", "value": "/dev/nvme2n1"}
]'
# 注意：需要确认 ROOK_BLOCK_PATH 在 env 数组中的索引位置

# 方法 C：删除 Deployment 让 Operator 重新创建（需配合方案 2）
kubectl delete deployment rook-ceph-osd-13 -n rook-ceph
```

**方案 2：清除 Rook Operator 缓存**

```bash
# 重启 Rook Operator，让它重新读取 ConfigMap 中的 OSD 信息
kubectl rollout restart deployment rook-ceph-operator -n rook-ceph

# 删除 OSD 13 的 Deployment，强制 Operator 从 ConfigMap 重新读取
kubectl delete deployment rook-ceph-osd-13 -n rook-ceph
```

**验证修复**：
```bash
# 检查 OSD 13 Pod 状态
kubectl get pod -n rook-ceph -l ceph-osd-id=13

# 检查 Deployment 的环境变量
kubectl get deployment rook-ceph-osd-13 -n rook-ceph \
  -o jsonpath='{.spec.template.spec.containers[0].env}' | jq '.[] | select(.name=="ROOK_BLOCK_PATH")'
# 应该显示：{ "name": "ROOK_BLOCK_PATH", "value": "/dev/nvme2n1" }
```

### 3.2 长期修复方案（代码层面）

#### 3.2.1 修复 1：更新 OSD 信息时重新验证设备路径 ⭐ **推荐修复**

**文件**: `pkg/operator/ceph/cluster/osd/update.go`

**问题**：`updateExistingOSDs()` 函数直接从旧 Deployment 读取 `BlockPath`，不验证其正确性。

**修复建议**：在更新 OSD 时，重新从 `ceph-volume` 或 ConfigMap 读取设备信息。

```go
// update.go:148 之后添加验证逻辑
osdInfo, err := c.cluster.getOSDInfo(dep)
if err != nil {
    errs.addError("...")
    continue
}

// 【新增】验证 BlockPath 是否正确
// 通过 ceph-volume raw list 验证设备上的 OSD ID 是否匹配
if err := c.cluster.validateOSDDevice(osdInfo.ID, osdInfo.BlockPath); err != nil {
    log.NamespacedWarning(c.cluster.clusterInfo.Namespace, logger, 
        "OSD %d device path validation failed: %v. Re-fetching OSD info from ConfigMap.", osdInfo.ID, err)
    
    // 从 ConfigMap 重新读取 OSD 信息
    refreshedOSDInfo, err := c.cluster.getOSDInfoFromConfigMap(osdInfo.NodeName)
    if err != nil {
        errs.addError("failed to refresh OSD %d info from ConfigMap: %v", osdInfo.ID, err)
        continue
    }
    osdInfo = refreshedOSDInfo
}

c.osdDesiredState[osdID] = &osdInfo
```

#### 3.2.2 修复 2：添加设备路径变更检测

**文件**: `pkg/operator/ceph/cluster/osd/osd.go`

在 `getOSDInfo()` 函数中添加日志和告警：

```go
func (c *Cluster) getOSDInfo(d *appsv1.Deployment) (OSDInfo, error) {
    // ... 现有代码 ...
    
    for _, envVar := range container.Env {
        if envVar.Name == "ROOK_BLOCK_PATH" || envVar.Name == "ROOK_LV_PATH" {
            osd.BlockPath = envVar.Value
        }
        // ...
    }
    
    // 【新增】验证 BlockPath 和 OSD UUID 的一致性
    // 执行 ceph-volume raw list <BlockPath> 检查返回的 osd_uuid 是否匹配
    if osd.BlockPath != "" && osd.UUID != "" {
        actualUUID, err := c.getOSDUUIDFromDevice(osd.BlockPath)
        if err != nil {
            log.NamespacedWarning(c.clusterInfo.Namespace, logger,
                "OSD %d: failed to verify device %q: %v", osd.ID, osd.BlockPath, err)
        } else if actualUUID != osd.UUID {
            log.NamespacedError(c.clusterInfo.Namespace, logger,
                "OSD %d: UUID mismatch! BlockPath=%q has UUID=%s, expected %s. "+
                "This may cause OSD activation failure.", 
                osd.ID, osd.BlockPath, actualUUID, osd.UUID)
            // 可以选择返回错误或记录告警
        }
    }
    
    return osd, nil
}
```

#### 3.2.3 修复 3：增强 activate init container 的设备验证

**文件**: `pkg/operator/ceph/cluster/osd/spec.go`

当前 activate init container 已有设备验证逻辑（第 181-192 行），但可以增强：

```bash
# 当前逻辑
if ! ceph-volume raw list "$DEVICE" > "$OSD_LIST"; then
    echo '' > "$OSD_LIST"
fi

if ! find_device < "$OSD_LIST"; then
    ceph-volume raw list > "$OSD_LIST"
    DEVICE="$(find_device < "$OSD_LIST")"
fi

# 【增强】添加 UUID 验证
# 即使 find_device 成功，也要验证找到的设备的 UUID 是否匹配
if ! find_device < "$OSD_LIST"; then
    ceph-volume raw list > "$OSD_LIST"
    DEVICE="$(find_device < "$OSD_LIST")"
else
    # 验证找到的设备的 OSD UUID 是否匹配
    ACTUAL_UUID=$(python3 -c "
import sys, json
for _, info in json.load(sys.stdin).items():
    if info['osd_id'] == $OSD_ID:
        print(info['osd_uuid'], end='')
        sys.exit(0)
")
    if [ "$ACTUAL_UUID" != "$OSD_UUID" ]; then
        echo "ERROR: Device $DEVICE has UUID $ACTUAL_UUID, expected $OSD_UUID"
        echo "Scanning all devices to find the correct one..."
        ceph-volume raw list > "$OSD_LIST"
        DEVICE="$(find_device < "$OSD_LIST")"
    fi
fi
```

### 3.3 预防措施

1. **启用设备持久化命名**
   - 已经在 Helm values 中使用 `/dev/disk/by-id/` 路径 ✅
   - 确保 Rook 在整个流程中保持使用持久化路径

2. **定期备份 OSD 元数据**
   ```bash
   # 定期运行并备份
   ceph-volume raw list --format json > osd-metadata-backup.json
   ```

3. **升级 Rook 时注意**
   - 在更改资源配置前，先暂停 Rook Operator
   - 逐个重启 OSD Deployment，而不是一次性全部重启

4. **添加监控告警**
   - 监控 OSD Pod 的 `Init:CrashLoopBackOff` 状态
   - 监控 activate init container 的错误日志
   - 当检测到 `ROOK_BLOCK_PATH` 与设备 UUID 不匹配时发送告警

---

## 4. 总结

### 4.1 问题原因

**直接原因**：OSD 13 的 Deployment 中 `ROOK_BLOCK_PATH` 环境变量被错误设置为 `/dev/nvme1n1`（属于 OSD 2 的设备），而不是正确的 `/dev/nvme2n1`。

**根本原因**：Rook Operator 在更新现有 OSD Deployment 时，从旧 Deployment 中读取 `ROOK_BLOCK_PATH` 并传递给新 Deployment。当旧 Deployment 配置错误时，新 Deployment 会继承这个错误。

**问题触发**：e0bb2ce 提交更改 OSD 资源限制后，Rook Operator 重新创建所有 OSD Deployment，OSD 13 继承了旧 Deployment 中的错误 `ROOK_BLOCK_PATH` 配置。

### 4.2 影响范围

- **影响**：OSD 13 无法启动，导致 Ceph 集群数据可用性降低
- **范围**：仅影响 OSD 13，其他 OSD 正常运行
- **持续性**：如果不手动修复，问题会持续存在，因为每次 Rook Operator 重新创建 Deployment 都会继承错误配置

### 4.3 建议的修复优先级

1. **立即执行**：手动修正 OSD 13 Deployment 的 `ROOK_BLOCK_PATH` 环境变量为 `/dev/nvme2n1`
2. **短期**：在 Rook Operator 中 `getOSDInfo()` 函数添加设备路径验证逻辑，检测并告警不一致的配置
3. **长期**：修改 Rook Operator 更新逻辑，在更新 OSD 时从 ConfigMap 或 `ceph-volume` 重新读取设备信息，而不是从旧 Deployment 继承

### 4.4 后续跟进

- [ ] 手动修正 OSD 13 Deployment 的 `ROOK_BLOCK_PATH`
- [ ] 监控 OSD 13 启动后的状态
- [ ] 检查其他 OSD 是否存在类似问题
- [ ] 考虑在 Rook 项目中提交 issue 或 PR 修复此问题
- [ ] 添加监控告警：检测 `ROOK_BLOCK_PATH` 与设备 UUID 不匹配的情况

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
+ DEVICE=/dev/nvme1n1  # ← 错误的设备路径
...
+ ceph-volume raw list /dev/nvme1n1
{
    "b87af9f9-05e9-450f-b8c4-b9a902ccc00a": {
        "ceph_fsid": "356ad2aa-0c04-452f-a0e7-ded4c0a5899b",
        "device": "/dev/nvme1n1",
        "osd_id": 2,  # ← 该设备实际属于 OSD 2
        "osd_uuid": "b87af9f9-05e9-450f-b8c4-b9a902ccc00a",
        "type": "bluestore"
    }
}
+ find_device
no disk found with OSD ID 13
+ ceph-volume raw list
# 完整扫描显示 OSD 13 实际在 /dev/nvme2n1
{
    "46b9e094-5f47-4620-a417-d48cfcfb0d21": {
        "ceph_fsid": "356ad2aa-0c04-452f-a0e7-ded4c0a5899b",
        "device": "/dev/nvme2n1",  # ← OSD 13 的正确设备
        "osd_id": 13,
        "osd_uuid": "46b9e094-5f47-4620-a417-d48cfcfb0d21",
        "type": "bluestore"
    },
    ...
}
```

### A.2 相关 K8S 资源

```bash
# OSD 13 Deployment 环境变量
kubectl get deployment rook-ceph-osd-13 -n rook-ceph \
  -o jsonpath='{.spec.template.spec.containers[0].env}' | jq '.[] | select(.name=="ROOK_BLOCK_PATH" or .name=="ROOK_OSD_ID")'

# 输出（错误）:
# {
#   "name": "ROOK_OSD_ID",
#   "value": "13"
# }
# {
#   "name": "ROOK_BLOCK_PATH",
#   "value": "/dev/nvme1n1"  # ← 错误，应该是 /dev/nvme2n1
# }

# OSD 2 Deployment 环境变量（正确）
kubectl get deployment rook-ceph-osd-2 -n rook-ceph \
  -o jsonpath='{.spec.template.spec.containers[0].env}' | jq '.[] | select(.name=="ROOK_BLOCK_PATH" or .name=="ROOK_OSD_ID")'

# 输出（正确）:
# {
#   "name": "ROOK_OSD_ID",
#   "value": "2"
# }
# {
#   "name": "ROOK_BLOCK_PATH",
#   "value": "/dev/nvme1n1"  # ← 正确
# }
```

### A.3 设备信息

```bash
# m600 节点上的 NVMe 设备
/dev/nvme0n1 - OSD 4 (3.5TB Intel)
/dev/nvme1n1 - OSD 2 (2.9TB DAPUSTOR)  # ← OSD 13 错误引用了这个设备
/dev/nvme2n1 - OSD 13 (3.5TB Samsung)  # ← OSD 13 应该使用的设备
/dev/nvme3n1 - OSD 12 (7.0TB Intel)
```

### A.4 Rook 相关代码路径

**关键代码位置**：

1. **OSD 信息提取** (`osd.go:706-765`)
   ```go
   func (c *Cluster) getOSDInfo(d *appsv1.Deployment) (OSDInfo, error) {
       // 从 Deployment 环境变量读取 ROOK_BLOCK_PATH
       for _, envVar := range container.Env {
           if envVar.Name == "ROOK_BLOCK_PATH" || envVar.Name == "ROOK_LV_PATH" {
               osd.BlockPath = envVar.Value
           }
       }
       // ...
   }
   ```

2. **OSD Deployment 更新** (`update.go:148-155`)
   ```go
   osdInfo, err := c.cluster.getOSDInfo(dep)  // ← 从旧 Deployment 读取
   if err != nil {
       errs.addError("...")
       continue
   }
   c.osdDesiredState[osdID] = &osdInfo  // ← 保存 OSD 信息
   ```

3. **OSD Deployment 创建** (`spec.go:422`)
   ```go
   envVars = append(envVars, []v1.EnvVar{
       // ...
       blockPathEnvVariable(osd.BlockPath),  // ← 设置 ROOK_BLOCK_PATH
       // ...
   }...)
   ```

---

*报告结束*
