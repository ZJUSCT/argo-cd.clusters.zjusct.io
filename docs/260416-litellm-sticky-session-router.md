# LiteLLM Sticky Session Router 调研报告

> 调研日期：2026-04-15
> 基于 LiteLLM 源码：`tmp/260416_litellm/litellm`（当前主分支）
> 当前部署配置：`production/litellm/values/litellm-helm-1.82.3.yaml`

---

## 背景

我们为同一订阅计划（如智谱/GLM）配置了多个 API Key，对应 `model_list` 中多个 `model_name` 相同的 deployment。
队友认为 LiteLLM 会自动将相同 `model_name` 的 deployment 合并，并随机分发请求。
担忧点：随机路由会导致 provider 侧 prompt cache 命中率下降，增加 token 消耗。

---

## 第一部分：队友的说法是否正确？

**结论：正确。**

LiteLLM 的默认路由策略是 `simple-shuffle`（源码：`litellm/router_strategy/simple_shuffle.py`）。
当 `model_list` 中存在多个 `model_name` 相同的 deployment 时，LiteLLM 会将它们视为同一"部署组"（deployment group），每次请求从组内**随机**挑选一个 deployment 调用。

当前 `router_settings` 配置：

```yaml
router_settings:
  routing_strategy: simple-shuffle
```

以智谱 GLM 为例，`plan/zhipu/glm-5/openai` 对应两个 deployment（分别使用 `PLAN_ZHIPU_API_KEY` 和 `PLAN_ZHIPU_API_KEY_2`），每次请求被随机路由到两者之一。

---

## 第二部分：Cache 问题分析

你描述的问题是真实存在的：

1. 请求 R1 路由到 Key1 → Provider 将 KV Cache 存储在 Key1 账户下
2. 请求 R2 携带完整 session 历史路由到 Key2 → Provider 找不到 Key1 的缓存 → 全量计算 tokens，费用更高

这正是 **provider 侧 prompt cache** 的工作原理：缓存是按 API Key/Organization 隔离存储的，跨 key 不共享。随机路由会导致缓存命中率接近于 0（1/N，N 为 key 数量）。

---

## 第三部分：LiteLLM 是否已有 Sticky Session Router？

**结论：已有，且已合并到最新主分支，无需自行实现。**

### 3.1 现有机制一览

LiteLLM 目前提供三种 deployment affinity（路由亲和性）机制，统一在 `DeploymentAffinityCheck` 类中实现（`litellm/router_utils/pre_call_checks/deployment_affinity_check.py`）：

| 机制 | 配置值 | 路由依据 | 适用范围 | 说明 |
|------|--------|----------|----------|------|
| `deployment_affinity` | `optional_pre_call_checks: [deployment_affinity]` | LiteLLM API Key 哈希 | 所有 endpoint | 同一 LiteLLM Key 的所有请求路由到同一 deployment |
| `session_affinity` | `optional_pre_call_checks: [session_affinity]` | 请求中的 `session_id` | 所有 endpoint | 相同 session_id 的请求路由到同一 deployment |
| `responses_api_deployment_check` | `optional_pre_call_checks: [responses_api_deployment_check]` | `previous_response_id` | 仅 Responses API | 续接上一次响应时路由到同一 deployment |

此外还有一个 `prompt_caching` 检查，仅适用于带有显式 `cache_control: {type: ephemeral}` 标记的请求，不适用于一般 chat completion。

### 3.2 `session_affinity` 的工作原理

```
客户端请求携带 x-litellm-session-id 或 x-litellm-trace-id header
       ↓
LiteLLM Proxy 在 litellm_pre_call_utils.py 中解析 header，
写入 metadata["session_id"]
       ↓
Router.async_get_available_deployment 调用 DeploymentAffinityCheck.async_filter_deployments
       ↓
从 cache 查询 key = "deployment_affinity:v1:session:{model_group}:{session_id}"
       ↓
命中 → 返回对应 deployment（只有一个，强制路由）
未命中 → 返回全部 healthy deployments（正常负载均衡）
       ↓
请求完成后，async_pre_call_deployment_hook 将本次 session_id → deployment_id 写入 cache（TTL 1小时）
```

关键代码位置：
- `deployment_affinity_check.py:222` `get_session_affinity_cache_key()`
- `deployment_affinity_check.py:350-388` 读缓存并过滤 deployment
- `deployment_affinity_check.py:531-553` 写缓存

### 3.3 `deployment_affinity` 的工作原理

与 `session_affinity` 类似，但路由依据是 `metadata.user_api_key_hash`（LiteLLM 内部的 API Key 哈希），无需客户端传 session_id。

- 优点：无需客户端改动
- 缺点：如果多个用户/会话使用同一个 LiteLLM API Key，则所有请求都被路由到同一个 deployment，负载均衡能力受到影响

### 3.4 关于 Responses API 与通用 API 的关系

> 任务中提到：`v1.67.4-stable` 的 Release Notes 描述的是 Responses API 的 session continuity，是否适用于 Anthropic API 和通用场景？

**答：`deployment_affinity` 和 `session_affinity` 对所有 provider 和所有 endpoint 均有效，不限于 Responses API。**

具体验证依据：
- `async_filter_deployments` 在 `router.py:6643-6670` 中被 `async_callback_filter_deployments` 调用
- 该函数在 `router.py:9256` 被 `async_get_available_deployment` 调用
- `async_get_available_deployment` 被所有调用路径使用，包括 `acompletion`（chat/completions endpoint）

`responses_api_deployment_check` 仅解析 `previous_response_id` 字段，而 `deployment_affinity` 和 `session_affinity` 仅依赖 metadata 中的 key hash 或 session_id，与 provider 无关。

---

## 第四部分：关于被提到的历史 PR

### Issue #6784 + PR #7086（两年前）

PR #7086 实现了基于 `cache_control` 标记的 `PromptCachingDeploymentCheck`。
**现状**：该类仍存在（`prompt_caching_deployment_check.py`），但已被更通用的 `DeploymentAffinityCheck` 补充。

区别：
- `PromptCachingDeploymentCheck`：只在消息中有 `cache_control: {type: ephemeral}` 且 token 数 ≥ 1024 时起效，路由依据是消息内容的哈希（prefix hash）
- `DeploymentAffinityCheck`：基于 API Key 或 Session ID，与消息内容无关，更通用

两年来的变化：新增了 `DeploymentAffinityCheck`，原来 `ResponsesApiDeploymentCheck` 已被标记为 `@deprecated`（`responses_api_deployment_check.py:24-31`），建议改用 `DeploymentAffinityCheck(enable_responses_api_affinity=True)`。

---

## 第五部分：我们当前配置的差距

### 当前配置（无 sticky session）

```yaml
router_settings:
  routing_strategy: simple-shuffle
  # 未配置 optional_pre_call_checks
```

### 需要补充的配置

```yaml
router_settings:
  routing_strategy: simple-shuffle
  optional_pre_call_checks:
    - session_affinity      # 基于 session_id 的粘性路由（推荐）
    # 或
    - deployment_affinity   # 基于 LiteLLM API Key 的粘性路由（无需客户端改动）
  deployment_affinity_ttl_seconds: 3600  # 默认值，可根据会话时长调整
```

### Redis 的要求

目前配置为 `redis.enabled: false` 且 `replicaCount: 1`。
- **单副本**：可用内存缓存，session_affinity 可用，但 Pod 重启后缓存丢失
- **多副本或 Pod 重启后需要保持亲和性**：需要启用 Redis

当前 `replicaCount: 1`，可以不用 Redis 先试效果。

---

## 第六部分：推荐方案

### 方案 A：`session_affinity`（推荐）

**工作方式**：客户端在每次请求中通过 HTTP header 传入一个稳定的 session ID，同一 session 的所有请求被路由到同一 deployment。

**LiteLLM 侧配置**（`proxy_config` 中的 `router_settings`）：

```yaml
router_settings:
  routing_strategy: simple-shuffle
  optional_pre_call_checks:
    - session_affinity
  deployment_affinity_ttl_seconds: 3600
```

**客户端侧**：在请求 header 中添加：

```
x-litellm-session-id: <稳定的会话标识，例如 Claude Code 的 conversation_id>
# 或等价地
x-litellm-trace-id: <同上>
```

Python SDK 调用方式：
```python
litellm_metadata={"session_id": "your-session-id"}
```

**优点**：
- 负载均衡粒度细（不同 session 仍能分散到不同 deployment）
- 对所有 provider 和 endpoint 有效
- TTL 到期后自动重新平衡

**缺点**：
- 需要客户端（如 Claude Code 等前端）传递一致的 session_id

### 方案 B：`deployment_affinity`（无需客户端改动）

**工作方式**：同一 LiteLLM API Key 的所有请求路由到同一 deployment，无需客户端做任何改动。

**配置**：

```yaml
router_settings:
  routing_strategy: simple-shuffle
  optional_pre_call_checks:
    - deployment_affinity
  deployment_affinity_ttl_seconds: 3600
```

**优点**：无需改动客户端

**缺点**：
- 如果所有客户端共用同一个 LiteLLM Key，所有请求都路由到同一 deployment，负载均衡失效
- 如果不同用户使用不同 LiteLLM Key，则粒度合理（每个 key 对应一个 deployment）

### 方案 C：两者同时启用

```yaml
optional_pre_call_checks:
  - session_affinity      # 优先（有 session_id 时优先使用）
  - deployment_affinity   # 兜底（没有 session_id 时回退到 key 级别亲和）
```

### 方案 D：`model_group_affinity_config`（精细化控制）

只对有多个 Key 的 model group 开启亲和性，其余保持随机负载均衡：

```yaml
router_settings:
  routing_strategy: simple-shuffle
  model_group_affinity_config:
    "plan/zhipu/glm-5/openai":
      - session_affinity
    "plan/zhipu/glm-5/anthropic":
      - session_affinity
    # ... 其他有多 Key 的 model group
```

---

## 第七部分：结论

| 问题 | 答案 |
|------|------|
| LiteLLM 是否随机路由同名 deployment？ | **是**，默认 `simple-shuffle` |
| 随机路由会导致 provider cache miss？ | **是**，provider 侧 KV cache 按 key 隔离 |
| LiteLLM 是否已有 Sticky Session？ | **是**，`DeploymentAffinityCheck`，在最新代码中已稳定实现 |
| 是否仅限 Responses API？ | **否**，`session_affinity` 和 `deployment_affinity` 对所有 provider 和 endpoint 有效，包括 Anthropic `chat/completions` |
| 实现难度如何？ | **极低**，只需修改 `router_settings` 配置，无需改动代码 |
| 是否需要 Redis？ | 单副本部署下不需要；如果需要跨副本或 Pod 重启持久化则需要 Redis |

**推荐立即行动**：在 `router_settings` 中添加 `optional_pre_call_checks: [session_affinity, deployment_affinity]`，并让客户端传递 `x-litellm-session-id` header。这是零代码改动的配置级方案，已在 LiteLLM 最新版本中实现。
