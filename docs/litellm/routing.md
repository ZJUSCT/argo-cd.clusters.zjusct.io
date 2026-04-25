# LiteLLM Router 路由策略笔记

> 来源：https://docs.litellm.ai/docs/routing

## 核心概念

LiteLLM Router 负责：
- 跨多个 deployment 的负载均衡
- 重要请求的优先级队列
- 基础可靠性：cooldown、fallback、超时与重试

`model_list` 中同名 `model_name` 的多个 deployment 会被视为同一组，由 router 在组内分配请求。

---

## 路由策略（routing_strategy）

| 策略 | 说明 |
|---|---|
| `simple-shuffle`（**默认，推荐**） | 按 rpm/tpm 权重随机选择；未设置 rpm/tpm 时纯随机 |
| `latency-based-routing` | 优先选延迟最低的 deployment |
| `usage-based-routing` | 按当前用量路由（有性能开销） |
| `least-busy` | 优先选并发最少的 deployment |
| `cost-based-routing` | 优先选费用最低的 deployment |

**生产推荐**：`simple-shuffle`，延迟开销最小。

### RPM/TPM 权重配置

```yaml
model_list:
  - model_name: gpt-3.5-turbo
    litellm_params:
      model: azure/chatgpt-v-2
      rpm: 900   # 高权重，被选中概率更高
  - model_name: gpt-3.5-turbo
    litellm_params:
      model: azure/chatgpt-functioncalling
      rpm: 10    # 低权重
```

### 固定权重（weight）

```yaml
litellm_params:
  weight: 2   # 被选中概率是 weight=1 的 2 倍
```

---

## 部署优先级（order）

设置 `litellm_params.order`（数值越小优先级越高）。高优先级 deployment 失败时自动降级到下一级。

```yaml
litellm_params:
  order: 1  # 最高优先级；失败后尝试 order=2
```

每个优先级级别都有独立的重试次数，全部耗尽后再触发 fallback。

---

## 可靠性机制

### Cooldown（冷却）

deployment 失败超过阈值后暂时移出可用池。

```yaml
router_settings:
  allowed_fails: 0       # 首次失败立即冷却（0 = 零容忍）
  cooldown_time: 600     # 冷却时长（秒）
  disable_cooldowns: false
```

**触发冷却的条件：**

| 条件 | 触发 | 默认冷却时长 |
|---|---|---|
| 限流 (429) | 立即 | 5s |
| 失败率 >50%/分钟 | 立即 | 5s |
| 不可重试错误 (401/404/408) | 立即 | 5s |

冷却期间该 deployment 自动排除，冷却结束后自动恢复。

### Retries（重试）

```yaml
router_settings:
  num_retries: 2       # 失败后最多重试次数（每次换不同 deployment）
  retry_after: 0       # 重试前最短等待秒数
```

- RateLimitError：指数退避
- 其他通用错误：立即重试

### 按错误类型自定义重试/冷却

```yaml
# proxy config.yaml
router_settings:
  retry_policy:
    RateLimitErrorRetries: 3
    AuthenticationErrorRetries: 0
    ContentPolicyViolationErrorRetries: 3
  allowed_fails_policy:
    RateLimitErrorAllowedFails: 100
    ContentPolicyViolationErrorAllowedFails: 1000
```

---

## Session Affinity（会话亲和）

> ⚠️ **当前使用中，存在已知问题，见下方注意事项**

让同一会话的请求始终路由到同一 deployment（用于利用上游 KV Cache 等场景）。

```yaml
router_settings:
  optional_pre_call_checks:
    - session_affinity
  deployment_affinity_ttl_seconds: 3600  # 亲和关系缓存时长（秒）
```

**工作原理**：Router 读取 `metadata["session_id"]`，通过内存 cache（单副本）或 Redis（多副本）记录 session → deployment 映射，TTL 内复用同一 deployment。

**⚠️ 与 cooldown 的冲突问题**：
- `session_affinity` TTL（3600s）远长于 `cooldown_time`（600s）
- deployment 冷却期结束恢复后，session 仍亲和到它，若其额度未恢复则再次失败，形成循环
- **根本原因**：session affinity 会优先选择绑定的 deployment，即使它处于 cooldown 中

**解决方案选项**：
1. 移除 `session_affinity`（最简单，cooldown 机制已能规避限额 deployment）
2. 将 `deployment_affinity_ttl_seconds` 缩短至小于 `cooldown_time`（如 `< 600s`）

---

## Pre-Call Checks（预检）

```yaml
router_settings:
  enable_pre_call_check: false  # 过滤超出 context window 或不符合区域要求的 deployment
  optional_pre_call_checks:
    - session_affinity
```

- `enable_pre_call_check`：过滤 context window 不足或不在目标 region 的 deployment
- `optional_pre_call_checks: [session_affinity]`：启用会话亲和预检

---

## 并发控制

```yaml
router_settings:
  default_max_parallel_requests: null  # 每个 deployment 最大并发，null 为不限

# 或在 litellm_params 中单独设置
litellm_params:
  max_parallel_requests: 10
```

若设置了 rpm/tpm 且未设置 max_parallel_requests，LiteLLM 会自动以 rpm（或 tpm/1000/6）作为并发上限。

---

## Caching（响应缓存）

```yaml
router_settings:
  cache_responses: false  # 开启后相同请求直接返回缓存

# 使用 Redis（生产推荐）
redis_host: ...
redis_password: ...
redis_port: ...
```

# 当前仓库配置：

## 实际工作模式：多订阅 + Session Affinity + Cooldown 限额自动切换

本仓库配置了多个智谱（Zhipu）订阅（ZBL、GH、ZSY），它们在 `model_list` 中共享相同的 `model_name`（如 `plan/zhipu/glm-5-turbo/openai`），仅通过不同的 `api_key` 区分。结合 Session Affinity 和 Cooldown 机制，实现了**订阅限额时自动无感切换**。

### 工作流程

```
Claude Code 发起请求（携带 x-claude-code-session-id）
    │
    ▼
LiteLLM Session Affinity Hook → 将 session_id 写入 metadata
    │
    ▼
Router 检查该 session 是否已绑定 deployment
    │
    ├── 已绑定 → 直接路由到绑定的 deployment（即使它处于 cooldown 中）
    │   ├── 成功 → 正常返回
    │   └── 失败 → cooldown 生效，但 session 绑定仍然存在
    │       └── 下次请求 → session affinity 仍然强制路由到同一个 deployment → 再次失败
    │           └── 循环，直到 session 绑定被清除
    │
    └── 未绑定 → simple-shuffle 随机选一个 → 建立绑定（乐观缓存，不考虑成功/失败）
```

> **⚠️ 已知问题**：LiteLLM 的 session affinity 优先级高于 cooldown。绑定建立后即使 deployment 处于 cooldown 中，请求仍会被强制路由到该 deployment。此外，首次路由时乐观缓存（无论成功失败都会缓存绑定），可能把 session 绑到已限额的 deployment 上。
>
> **解决方案**：通过自定义 Hook 在失败时清除 session affinity 缓存，实现"首次路由失败则重选，成功后才固定"的懒绑定策略（见下方 Session Affinity 实现部分）。

### 配置要点

```yaml
# model_list 中同一 model_name 注册了 3 个不同的订阅
- model_name: plan/zhipu/glm-5-turbo/openai
  litellm_params:
    api_key: os.environ/PLAN_ZHIPU_PRO_ZBL     # 订阅 A
- model_name: plan/zhipu/glm-5-turbo/openai
  litellm_params:
    api_key: os.environ/PLAN_ZHIPU_PRO_GH      # 订阅 B
- model_name: plan/zhipu/glm-5-turbo/openai
  litellm_params:
    api_key: os.environ/PLAN_ZHIPU_PRO_ZSY      # 订阅 C

router_settings:
  routing_strategy: simple-shuffle

  optional_pre_call_checks:
    - session_affinity
  deployment_affinity_ttl_seconds: 3600    # session 绑定 1 小时

  allowed_fails: 0                         # 首次失败立即冷却（零容忍）
  cooldown_time: 600                       # 冷却 10 分钟
  num_retries: 2                           # 失败后最多重试 2 次（换不同 deployment）
```

### 各参数的作用

| 参数 | 值 | 作用 |
|------|-----|------|
| `allowed_fails` | `0` | 订阅首次返回错误（如 429 限流）就立即 cooldown，避免持续请求已限额的订阅 |
| `cooldown_time` | `600` | 冷却 10 分钟，给限额恢复留出足够时间 |
| `deployment_affinity_ttl_seconds` | `3600` | session 绑定 1 小时，期间复用同一订阅（利用上游 KV Cache） |
| `num_retries` | `2` | 如果当前选中的 deployment 失败，换一个重试最多 2 次 |
| `routing_strategy` | `simple-shuffle` | session 未绑定或绑定失效时，按权重随机选择（无权重时纯随机） |

### Session Affinity 实现（懒绑定 + 失败清缓存）

通过自定义 `CustomLogger` hook 解决 LiteLLM 原生 session affinity 的问题：
- 乐观缓存 — 首次路由无论成功失败都会绑定 deployment
- 绑定优先于 cooldown — 即使 deployment 在 cooldown 中，session affinity 仍强制路由到它

**核心思路**：首次请求不设 `session_id`，让 LiteLLM 的 normal routing（simple-shuffle + cooldown + retries）自行处理。首次成功后，尝试预写 affinity cache（保留 KV Cache），后续请求通过 session affinity 固定到同一 deployment。已绑定 session 失败时清除 cache，让下次请求重新路由。

```
新 session 首次请求（不设 session_id）
    │
    ▼
normal routing: simple-shuffle 随机选（cooldown + retries 正常生效）
    │
    ├── 选中健康的 A → 成功 → 确认 session
    │   │
    │   ▼
    │   预写 affinity cache（key: session→A 的 model_id）
    │   │
    │   ▼
    │   后续请求：设 session_id → cache 命中 → 固定到 A → KV Cache 持续命中 ✅
    │
    └── 选中已限额的 B → 失败 → cooldown 排除 B
        │
        ▼
    num_retries 从剩余健康的 deployment 中选（A 或 C）→ 成功 → 确认 session
        │
        ▼
    后续请求固定到选中的 deployment → KV Cache 持续命中 ✅

已绑定的 session 遇到失败
    │
    ▼
清除 LiteLLM affinity cache → session 降级为 pending
    │
    ▼
下次请求：不设 session_id → normal routing → 选到健康的 → 重新绑定
```

Hook 通过 ConfigMap 挂载到 Pod，在 `litellm_settings.callbacks` 中注册：

```yaml
litellm_settings:
  callbacks: [ "otel", "prometheus", "hooks.claude_code_session.proxy_handler_instance" ]
```

完整实现见 `production/litellm/resources/configmap-claude-code-session-hook.yaml`。

### 已知限制

- 单副本部署，session 映射存储在 Hook 和 LiteLLM 的内存中，Pod 重启后映射丢失
- 如果所有 3 个订阅同时达到限额，请求会全部失败，需等待 cooldown 恢复
- 首次成功到 session affinity 生效之间可能有一次请求走 normal routing（不同的 deployment），损失一次 KV Cache
