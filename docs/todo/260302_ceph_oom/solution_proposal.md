# Rook Ceph MDS OOM 问题解决方案

## 方案概述

针对 Rook Ceph Operator 在 MDS OOM 后无法更新 Deployment 资源限制的问题，提出以下解决方案。

## 问题回顾

1. MDS OOM 后，CephFS 处于 degraded 状态
2. 用户更新 CephFilesystem 的内存限制
3. Operator 尝试更新 MDS Deployment，但被 `ceph mds ok-to-stop` 检查阻止
4. 形成死循环：无法更新内存限制 → MDS 无法恢复 → 始终 degraded

## 解决方案

### 方案一：修改 Operator 逻辑，优先创建缺失的 Daemon（推荐）

#### 设计思路

参考 GitHub Issue #16702 中社区讨论的建议，修改 Operator 的行为：**当检测到需要创建新的 MDS（或 MDS 需要重建）时，优先创建而不是更新现有的 MDS**。

具体修改位置：`pkg/operator/ceph/file/mds/mds.go` 的 `Start()` 函数

#### 实现步骤

1. **在 `Start()` 函数中，区分创建和更新场景**：
   - 检测哪些 MDS deployment 缺失
   - 优先创建缺失的 MDS deployment，不进行 `ok-to-stop` 检查
   - 创建完成后再处理现有 MDS 的更新

2. **修改 `startDeployment` 函数**：
   - 添加参数 `isNewDeployment bool`
   - 如果是新建 deployment，跳过 `UpdateDeploymentAndWait` 中的 `ok-to-stop` 检查
   - 直接创建 deployment

3. **实现伪代码**：

```go
func (c *Cluster) Start() error {
    // ... 现有代码 ...
    
    // 1. 首先创建所有缺失的 MDS deployment（不检查 ok-to-stop）
    for i := 0; i < int(replicas); i++ {
        mdsDaemonName := k8sutil.IndexToName(i)
        
        // 检查 deployment 是否存在
        deploymentExists, err := c.checkDeploymentExists(mdsDaemonName)
        if err != nil {
            return err
        }
        
        if !deploymentExists {
            // 缺失的 deployment，直接创建，不检查 ok-to-stop
            _, err := c.createDeploymentWithoutUpgradeCheck(mdsDaemonName)
            if err != nil {
                return err
            }
        }
    }
    
    // 2. 然后更新现有的 MDS deployment（正常检查 ok-to-stop）
    for i := 0; i < int(replicas); i++ {
        mdsDaemonName := k8sutil.IndexToName(i)
        
        deployment, err := c.startDeployment(...)
        // 这里会正常执行 ok-to-stop 检查
        ...
    }
    
    return nil
}
```

#### 风险和应对措施

| 风险 | 应对措施 |
|------|----------|
| 跳过检查可能导致数据不一致 | 仅对缺失的 deployment 跳过检查，现有 MDS 仍需检查 |
| 多个 MDS 同时创建可能压力大 | 顺序创建，每个成功后再创建下一个 |
| 可能引入新的 bug | 充分测试，特别是升级场景 |

### 方案二：添加新的 CRD 配置项

#### 设计思路

在 CephFilesystem CRD 中添加新的配置项，允许用户控制是否跳过 MDS 的 `ok-to-stop` 检查。

#### 实现步骤

1. **修改 CephFilesystem CRD**（`pkg/apis/ceph.rook.io/v1/types.go`）：
   ```go
   type MetadataServerSpec struct {
       // ... 现有字段 ...
       
       // ForceUpdate 表示强制更新 MDS，不检查 ok-to-stop
       // +optional
       ForceUpdate bool `json:"forceUpdate,omitempty"`
   }
   ```

2. **修改 `startDeployment` 函数**：
   - 读取 CephFilesystem 的 `ForceUpdate` 配置
   - 如果为 true，跳过 `ok-to-stop` 检查

3. **更新 Helm values 文档**：
   - 添加新配置项的说明

#### 风险和应对措施

| 风险 | 应对措施 |
|------|----------|
| 用户可能滥用此功能导致问题 | 添加警告文档，说明使用场景 |
| 需要修改 CRD，兼容性问题 | 保持向后兼容，默认值为 false |

### 方案三：临时解决方案（无需修改代码）

#### 设计思路

在紧急情况下，用户可以通过手动操作来绕过这个问题。

#### 操作步骤

1. **临时移除 MDS 的资源限制**：
   ```bash
   # 找到 MDS deployment
   kubectl get deployment -n rook-ceph -l app=rook-ceph-mds
   
   # 编辑 deployment，移除 resource limits
   kubectl edit deployment -n rook-ceph <mds-deployment-name>
   ```

2. **降低 CephFS 的活性要求**：
   - 使用 `ceph fs set <fs_name> joinable true` 允许 MDS 加入

3. **手动重启 MDS**：
   ```bash
   # 删除 MDS pods，让 Operator 重新创建
   kubectl delete pod -n rook-ceph -l app=rook-ceph-mds
   ```

4. **在 MDS 恢复后，更新内存限制**：
   - 修改 Helm values
   - 应用更改

#### 风险和应对措施

| 风险 | 应对措施 |
|------|----------|
| 需要人工干预 | 记录操作手册 |
| 可能再次 OOM | 逐步增加内存限制，监控行为 |

## 推荐方案

**推荐方案一**：修改 Operator 逻辑，优先创建缺失的 Daemon

理由：
1. 从根本上解决问题，不需要用户手动干预
2. 与 GitHub Issue #16702 的社区讨论方向一致
3. 不会引入新的配置项，保持 API 简洁
4. 只在真正需要创建新 deployment 时跳过检查，更安全

## 实施计划

### Phase 1: 代码修改
1. 在 `mds.go` 中添加 `checkDeploymentExists` 函数
2. 修改 `Start()` 函数逻辑，区分创建和更新
3. 添加 `createDeploymentWithoutUpgradeCheck` 函数
4. 单元测试

### Phase 2: 测试
1. 模拟 MDS OOM 场景
2. 验证更新内存限制后可以成功恢复
3. 测试升级场景

### Phase 3: 文档
1. 更新 Rook 文档
2. 添加故障排查指南

## 总结

Rook Ceph MDS OOM 问题的根本原因是 Operator 在更新 MDS Deployment 时强制要求通过 `ceph mds ok-to-stop` 健康检查，而这个检查在 CephFS 处于 degraded 状态时无法通过，形成死循环。

解决方案的核心思路是：**当需要创建新的 MDS deployment 时，优先创建而不是更新**，这样可以绕过健康检查，让 MDS 尽快恢复运行。恢复后，再处理现有 MDS 的更新。
