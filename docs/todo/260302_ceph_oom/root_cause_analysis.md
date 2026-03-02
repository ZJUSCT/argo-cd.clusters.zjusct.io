# Rook Ceph MDS OOM 问题根本原因分析

## 问题概述

当 CephFS 的 MDS（Metadata Server）因内存占用过高导致 OOM Kill 后，即使修改了 CephFilesystem 的内存限制配置，Rook Ceph Operator 也无法成功更新 MDS Deployment 的资源限制，导致 MDS 持续 OOM，形成死循环。

## 根本原因分析

### 1. 直接原因

问题的直接原因位于 `pkg/operator/k8sutil/deployment.go` 的 `UpdateDeploymentAndWait` 函数（第 69-116 行）：

```go
// 第 91-96 行
// Let's verify the deployment can be stopped
if err := verifyCallback("stop"); err != nil {
    return fmt.Errorf("failed to check if deployment %q can be updated. %v", modifiedDeployment.Name, err)
}
```

在更新 MDS Deployment 之前，Operator 会调用 `verifyCallback("stop")` 来检查 MDS 是否可以安全停止。这个回调函数定义在 `pkg/operator/ceph/cluster/mon/spec.go` 的 `UpdateCephDeploymentAndWait` 函数（第 393-429 行）：

```go
// 第 402-410 行
if action == "stop" {
    err := client.OkToStop(context, clusterInfo, deployment.Name, daemonType, daemonName)
    if err != nil {
        if continueUpgradeAfterChecksEvenIfNotHealthy {
            log.NamespacedInfo(...)
            return nil
        }
        return errors.Wrapf(err, "failed to check if we can %s the deployment %s", action, deployment.Name)
    }
}
```

`OkToStop` 函数（`pkg/daemon/ceph/client/upgrade.go` 第 117-162 行）会执行 `ceph mds ok-to-stop` 命令来检查 MDS 是否可以安全停止。当 CephFS 处于 degraded 状态时（例如 MDS OOM 后），这个命令会返回错误：

```
Error EBUSY: one or more filesystems is currently degraded
```

### 2. 问题本质：鸡生蛋困境

这个问题的本质是一个经典的鸡生蛋困境：

1. **要恢复 MDS 正常运行**：需要增加 MDS 的内存限制
2. **要更新内存限制**：需要先停止现有的 MDS Pod
3. **要停止 MDS Pod**：需要 CephFS 处于健康状态
4. **MDS 无法恢复健康**：因为内存不足导致 OOM

### 3. 与 GitHub Issue #16702 的关联

这个问题与 Rook GitHub Issue #16702（MON 的类似问题）有相同的根本原因：

> "operator doesn't prioritize creating missing mon deployments over reconfiguring existing ones?"

核心问题是 **Operator 优先处理现有 daemon 的配置更新（需要停止 daemon），而不是优先处理恢复缺失/不健康的 daemon**。

在 MDS 的场景中：
- 即使 MDS deployment 被删除，Operator 仍然尝试更新（重新创建）MDS
- 但在创建过程中，Operator 仍然需要检查是否可以安全替换
- 这个检查在 degraded 状态下无法通过

### 4. 代码位置总结

| 文件 | 行号 | 描述 |
|------|------|------|
| `pkg/operator/k8sutil/deployment.go` | 91-96 | 调用 stop 检查回调 |
| `pkg/operator/ceph/cluster/mon/spec.go` | 402-410 | 执行 `ceph mds ok-to-stop` |
| `pkg/daemon/ceph/client/upgrade.go` | 117-162 | `OkToStop` 函数实现 |
| `pkg/daemon/ceph/client/upgrade.go` | 178-195 | `okToStopDaemon` 执行实际命令 |
| `pkg/operator/ceph/file/mds/mds.go` | 237-241 | MDS deployment 更新逻辑 |

### 5. 为什么删除 MDS deployment 后问题仍然存在

当用户手动删除 MDS deployment 后，Rook Operator 会尝试重新创建 MDS deployment。但在 `startDeployment` 函数（`pkg/operator/ceph/file/mds/mds.go` 第 225-241 行）中：

1. 尝试创建 deployment
2. 如果 deployment 已存在（这是重建的情况），则调用 `UpdateDeploymentAndWait`
3. `UpdateDeploymentAndWait` 仍然会检查 `ok-to-stop`

即使 MDS 是新创建的，它仍然需要与现有的 MDS 协调（如果有多个 MDS），而 CephFS 仍然处于 degraded 状态，所以检查仍然会失败。

## 结论

问题的根本原因是 **Rook Ceph Operator 在更新 MDS Deployment 时，强制要求通过 `ceph mds ok-to-stop` 健康检查，而这个检查在 CephFS 处于 degraded 状态时无法通过**。

这形成了一个无法自动恢复的死循环，需要人工干预或修改 Operator 的行为来解决。
