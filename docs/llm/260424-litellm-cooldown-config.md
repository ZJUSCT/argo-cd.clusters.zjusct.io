# LiteLLM Cooldown 配置说明

> 修改日期：2026-04-24
> 涉及文件：`production/litellm/values/litellm-helm-1.82.3.yaml`

---

## 背景

我们为同一订阅计划配置了多个 API Key（ZBL、GH、ZSY），LiteLLM 将它们视为同一 model group，每次随机路由到其中一个。

当某个上游账户达到配额限制时，会出现：
- 新会话 1/N 概率被路由到限额账户（N 为同组 key 数量）
- session_affinity 将 session 绑定到限额账户后，后续请求持续失败
- 用户需要重建会话才能恢复

---

## Cooldown 机制

Cooldown 是 LiteLLM 的内置熔断机制：当一个部署连续失败一定次数后，将其从健康列表中暂时剔除，不再接收新请求。

剔除发生在 `async_get_healthy_deployments` 中，**早于** session affinity 检查：

```
获取所有部署 → 剔除 cooldown 部署 → session affinity 过滤 → 路由策略选择
```

所以 cooldown 的部署：
- **新 session**：从一开始就不在可用池里，不会被选中
- **已有 affinity 的 session**：affinity 在健康池中找不到绑定的部署，自动降级返回全部健康部署

Cooldown 是**全局**的，对所有用户和所有 session 同时生效。

### 关键参数

| 参数 | 含义 |
|------|------|
| `allowed_fails` | 触发 cooldown 前允许的失败次数。0 = 首次失败立即 cooldown |
| `cooldown_time` | 部署被拉黑的持续时间（秒） |

---

## 当前配置

```yaml
router_settings:
  routing_strategy: simple-shuffle
  optional_pre_call_checks:
    - session_affinity
  deployment_affinity_ttl_seconds: 3600

  allowed_fails: 3          # 累计第 4 次失败才触发 cooldown
  cooldown_time: 30         # 只拉黑 30 秒
  disable_cooldowns: false

  num_retries: 2            # LiteLLM 子重试（同一 HTTP 请求内）
  retry_after: 0
```

### 问题

当限额账户出现时的交互流程：

```
[Claude Code] 第1次尝试 → LiteLLM 走 ZBL → 限额失败
              → 2 次子重试仍走 ZBL（session affinity 绑死了）→ 3 次全挂
              → 失败计数器 = 3，3 > 3 为假，未触发 cooldown
              → 返回错误

[Claude Code] 等 13 秒 → 第2次尝试（新的 HTTP 请求）
              → session affinity 仍指向 ZBL → 失败
              → 失败计数器 = 4，4 > 3 为真 → 触发 cooldown 30s
              → 重试 → ZBL 在 cooldown 中 → session affinity 降级 → 选到 GH → 成功
              → session 绑定更新为 GH
              ↓
              但 30 秒后 ZBL 解封，如果仍限额，新 session 可能再次命中
```

`allowed_fails: 3` 导致需 4 次失败才 cooldown，30 秒拉黑时间过短。结合 Claude Code 客户端约 13 秒间隔最多重试 10 次的行为，可能出现持续 2 分钟的重试窗口。

---

## 修改后配置

```yaml
router_settings:
  routing_strategy: simple-shuffle
  optional_pre_call_checks:
    - session_affinity
  deployment_affinity_ttl_seconds: 3600

  allowed_fails: 0          # 首次失败立即触发 cooldown
  cooldown_time: 600        # 拉黑 10 分钟，匹配配额限制的时间尺度
  disable_cooldowns: false

  num_retries: 2
  retry_after: 0
```

### 修改后流程

```
[Claude Code] 第1次尝试 → LiteLLM 走 ZBL → 限额失败
              → 失败计数器 = 1，1 > 0 为真 → 触发 cooldown 600s
              → 第1次子重试 → ZBL 在 cooldown 中 → session affinity 降级 → 选到 GH → 成功
              → session 绑定更新为 GH
              → 返回成功 ← Claude Code 收不到错误，不会等 13 秒重试

[新会话 · 10 分钟内]
              → ZBL 全局拉黑，不在可用列表中
              → 只在 GH / ZSY 之间二选一 → 正常

[10 分钟后]
              → ZBL 自动解封
              → 如果限额已解除 → 恢复正常三选一
              → 如果仍限额 → 首次失败再次触发 cooldown
```

### 效果对比

| 维度 | 修改前 | 修改后 |
|------|--------|--------|
| 首次触发 cooldown | 需 4 次失败 | 1 次失败即触发 |
| 坏账户拉黑时长 | 30 秒 | 600 秒（10 分钟） |
| 第一条消息 | Claude Code 重试窗口 ~2 分钟，可能多次失败 | LiteLLM 内部重试一次即恢复，客户端无感 |
| 新会话 | 30 秒后可能再次命中限额账户 | 10 分钟内不会碰到 |
| 多个用户并发 | 各用户需各自踩 4 次坑才触发 cooldown | 任意用户触发后，全员即时避让 |
| 恢复机制 | 30 秒后自动恢复 | 10 分钟后自动恢复 |

---

## 注意事项

- Cooldown 是内存级的（单副本部署下），Pod 重启后 cooldown 状态丢失。如果需要跨重启持久化，需启用 Redis
- `allowed_fails: 0` 假设下游 API 返回的 4xx/5xx 确实表示该部署不可用。如果网络抖动等瞬态故障频繁，可考虑 `allowed_fails: 1`
- 修改后仅改变熔断策略，不影响 session_affinity 的 sticky 路由行为
