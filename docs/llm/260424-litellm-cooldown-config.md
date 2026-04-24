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

---

## Cooldown 未生效问题排查

> 排查日期：2026-04-24
> LiteLLM 版本：1.82.3
> 触发条件：智谱 API 返回 429（code 1310，配额限制）

### 问题现象

配置 `allowed_fails: 0` + `cooldown_time: 600` 后，429 错误仍然持续出现。退出 session 后新建 session 可恢复（新 session 随机选中了另一个 deployment），说明 cooldown 在跨 session 场景下有效，但在同一 session 内的 router retry 完全无效。

### 根因

通过开启 `LITELLM_LOG=DEBUG`（ConfigMap `litellm-env-configmap`）后抓取日志，确认 cooldown **完全没有被触发**：

```
Router: Entering 'deployment_callback_on_failure'
Router: Exiting 'deployment_callback_on_failure' without cooldown. No model_info found.
```

`deployment_callback_on_failure`（`router.py:6053`）在失败回调中需要从 `litellm_params["model_info"]["id"]` 获取 deployment ID 才能触发 cooldown。但在 `_ageneric_api_call_with_fallbacks` 调用路径下（Anthropic passthrough endpoint 使用的路径），`model_info` 未能正确传递到 `failure_handler` 的 kwargs 中，导致回调直接返回 False，跳过 cooldown。

### 调用路径分析

Claude Code 通过 Anthropic 兼容 endpoint `/v1/messages` 发起请求，走的是 `anthropic_response()` → `base_process_llm_request()` → `_ageneric_api_call_with_fallbacks()` → `async_function_with_retries()` 路径，**不是**标准的 `_acompletion()` 路径。

标准路径 `_acompletion()` 通过 `_update_kwargs_with_deployment()` 注入 `model_info`，cooldown 可以正常工作。但 `_ageneric_api_call_with_fallbacks` 路径中，`_ageneric_api_call_with_fallbacks_helper` 虽然也调用了 `_update_kwargs_with_deployment()`，但 `model_info` 在异常传播到 `failure_handler` 时丢失了。

### Session Affinity 在 cooldown 失效时的表现

Session affinity 本身不会在失败时清除绑定，它依赖 cooldown 机制来间接实现故障转移：

1. 请求失败 → cooldown 将 deployment 从 healthy pool 移除
2. 下次请求 → affinity 在 healthy pool 中查找绑定 deployment → 找不到（已被 cooldown）→ 降级返回全部 healthy deployments

当 cooldown 不工作时，healthy pool 始终为满的 3 个，affinity 每次都能命中绑定的限额 deployment，表现为"绑死"。

### 日志中确认的完整流程

```
1. 3 个 deployment 全部 healthy（cooldown models: []）
2. session-id affinity hit -> deployment=e55510c1...（限额账户）
3. 429 错误 → deployment_callback_on_failure → No model_info found → cooldown 未触发
4. 重试（num_retries: 2）→ cooldown models 仍为 [] → affinity 仍命中同一 deployment → 再次 429
5. Router 抛出异常 → Claude Code 客户端约 6 秒后重新发起 HTTP 请求
6. 重复步骤 1-5，直到 Claude Code 放弃或用户切换 session
```

### 临时缓解方案

在 LiteLLM 修复此 bug 之前，可以考虑：

1. **降低 session_affinity TTL**：当前 3600 秒太长，缩短到 300 秒可减少"绑死"窗口
2. **同时启用 `deployment_affinity`**：作为 session affinity 的补充，按 LiteLLM API Key 哈希路由，不同用户分散到不同 deployment
3. **升级 LiteLLM**：检查新版本是否已修复此路径下的 `model_info` 传递问题
