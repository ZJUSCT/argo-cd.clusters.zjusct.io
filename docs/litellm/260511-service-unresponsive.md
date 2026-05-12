# 2026-05-11 LiteLLM 服务不可用：Event Loop 饱和

## 现象

- 所有外部请求严重超时：`/litellm/mcp` 29s，`/ui/` 30s+，`/v1/models` 49s
- Pod 状态 `Running`、`Ready`，健康检查正常
- Pod 日志中偶有 Prisma 错误，但非 `ClientNotConnectedError`（与 4-29 事故不同）
- 无 OOMKill、容器重启、或 `FailedScheduling` 事件

## 调用链

```
Client → Envoy Gateway → litellm Service (port 4000) → uvicorn (单 worker)
                                                            │
                                                            ├─→ 9 个流式 LLM 连接长期占住 event loop
                                                            ├─→ 新请求排队等待 event loop 时间片
                                                            └─→ DB 查询（Prisma）也得不到时间片 → 重连死循环
```

## 根本原因：单 Worker Event Loop 饱和

### 1. `numWorkers` 被注释，退化为单 worker

`proxy_cli.py` 使用 uvicorn 启动 server，`--num_workers` 控制 worker 进程数：

**`/app/litellm/proxy/proxy_cli.py:1097-1100`**：

```python
uvicorn.run(
    **uvicorn_args,
    workers=num_workers,     # 默认值 = 1 (DEFAULT_NUM_WORKERS_LITELLM_PROXY)
)
```

默认值定义于 **`/app/litellm/constants.py:23-24`**：

```python
DEFAULT_NUM_WORKERS_LITELLM_PROXY = int(
    os.getenv("DEFAULT_NUM_WORKERS_LITELLM_PROXY", 1)
)
```

Helm Chart 中 `numWorkers` 字段控制是否传入 `--num_workers` 参数。修复前 `values.yaml` 中该字段被注释：

```yaml
# numWorkers: 2
```

模板判断逻辑（**`deployment.yaml:152-155`**）：

```yaml
{{ if .Values.numWorkers }}
- --num_workers
- {{ .Values.numWorkers | quote }}
{{- end }}
```

`numWorkers` 注释 → 模板不渲染 `--num_workers` → proxy_cli 取默认值 1 → 仅 1 个 uvicorn worker 进程，即仅 1 个 asyncio event loop。

### 2. Event Loop 饱和机制

Uvicorn 每个 worker 是单线程 asyncio event loop。核心约束：**一个 event loop 在同一时刻只能执行一个 coroutine**。

当 9 个流式 LLM API 连接（anthropic_messages passthrough）同时活跃时：

- 每个流式连接是一个长时间运行的 async generator（逐个 token 流式返回，持续数分钟）
- Event loop 在这些连接之间通过 `await` 切换，依赖 I/O 事件到达
- 流式连接持续有数据流入 → event loop 几乎无空闲
- 新的 HTTP 请求被 uvicorn 接收但无法获得 event loop 时间片处理
- 任何依赖 event loop 的操作（DB 查询、重连逻辑）同样被阻塞

### 3. 独立健康检查进程掩盖故障

LiteLLM 使用 `SEPARATE_HEALTH_APP=1` 配置，在端口 8081 启动一个**独立的 uvicorn 进程**，不经过主代理的 event loop。

K8s liveness/readiness 探针指向 port 8081，因此即使 port 4000 的主代理已完全不能服务请求，探针仍然成功 → Pod 保持 Ready → 无自动重启。

### 4. Prisma 错误是症状，不是原因

故障期间日志中出现 Prisma 连接错误（`All connection attempts failed`），但这**不是独立根因**。Prisma query engine 是独立 Rust 二进制进程，Python 端通过 HTTP 与之通信。当 event loop 饱和时：

1. Python 端无法向 query engine 发送 HTTP 请求 → 超时
2. Prisma wrapper 将超时解释为 "engine dead" → 触发重连逻辑
3. 重连逻辑本身也是 async → 同样需要 event loop → 同样无法执行
4. Error + backoff retry → 形成错误循环

这与 4-29 事故有本质区别：4-29 时 event loop 空闲，Prisma engine 进程确实死亡（PID=0），且因 `DATABASE_URL` 缺失无法重启。本次 event loop 本身即被占满，Prisma 错误是下游表现。

关于 `DATABASE_URL`：`proxy_cli.py` 启动时已调用 `construct_database_url_from_env_vars()` 从 `DATABASE_HOST/USERNAME/PASSWORD/NAME` 拼接出完整 URL 并写入 `os.environ`（`proxy_cli.py:811-818`），重连代码运行在同一进程中能找到。容器级不设 `DATABASE_URL` 是不一致但非本次根因。

## 修复：启用 Redis + 提高 numWorkers

单靠增大 `numWorkers` 不够。litellm Router 的多个核心状态——cooldown 冷却、session affinity、deployment affinity、spend 计数、TPM/RPM 追踪——默认存储在 `InMemoryCache`（Python dict）中。多 worker 时每个 worker 独立一份，互不可见。

### 状态隔离问题（无 Redis 时多 worker）

| 状态 | 源码位置 | 多 worker 后果 |
|------|----------|---------------|
| Cooldown 冷却 | `router_utils/cooldown_cache.py:34` | Worker A 冷却了 deployment X，Worker B 不知，继续路由过去 |
| Failed calls 计数 | `router.py:525` | 每个 worker 独立计数，N worker 需 N×allowed_fails 次失败才冷却 |
| Session affinity | `pre_call_checks/deployment_affinity_check.py:536` | Session 在 Worker A 绑定，请求落到 Worker B 则 KV cache 命中率为零 |
| Deployment affinity | `pre_call_checks/deployment_affinity_check.py:506` | API key 级别绑定丢失 |
| TPM/RPM 追踪 | Router 内部 | 速率限制跨 worker 不准 |
| Spend 计数 | `proxy_server.py:1727` | 花费统计不准 |

共享状态依赖 `DualCache`（**`router.py:460-461`**）：

```python
self.cache = DualCache(
    redis_cache=redis_cache, in_memory_cache=InMemoryCache()
)
```

`DualCache` 读路径先查内存缓存，不跨 worker 查询。只有启用 Redis 时，写操作才同步到 Redis，所有 worker 通过 Redis 读取共享状态。

### Redis 配置

Redis 是 Helm Chart 内置依赖，启用只需修改 values：

```yaml
redis:
  enabled: true
  architecture: standalone
```

同时启用 Router 缓存与认证缓存（**注意：必须放在 `litellm_settings` 下，不能放在 `router_settings` 下**）：

```yaml
proxy_config:
  litellm_settings:
    cache: true
    enable_redis_auth_cache: true
```

### numWorkers 数值选择

`uvicorn.run(workers=num_workers)` 使用 uvicorn 内置的多进程模式，每个 worker 是独立进程、独立 event loop。**有效并发 = numWorkers × 单 worker 异步并发**（单个 worker 可处理 50-100+ 并发流式连接）。

每 worker 增量内存约 200-250 MB（Python 进程 + Prisma engine 子进程 + 连接池）。当前 m601 节点资源充裕（CPU 4%，内存 13%），无资源压力。

对于数十个 Agent 同时使用（保守估计 20-40 并发流式连接）：`numWorkers: 4`。4 worker 提供 ~200 理论并发连接，即使 1-2 个 worker 被长时间流式连接占满，仍有 2-3 个 worker 处理新请求。

### 最终配置变更（commit `8312e49`）

```diff
-replicaCount: 1
-# numWorkers: 2
+numWorkers: 4

 proxy_config:
-  # (litellm_settings 行)
   router_settings:
+    cache: true
+    enable_redis_auth_cache: true

 redis:
-  enabled: false
+  enabled: true
+  architecture: standalone
```

同时移除了不必要的 `DATABASE_URL` Kustomize patch。

> **⚠️ 配置错误**：`cache: true` 和 `enable_redis_auth_cache: true` 被放在 `router_settings` 而非 `litellm_settings` 下。LiteLLM proxy_server.py 第 3629 行从 `litellm_settings` 遍历读取 `cache: true`，放在 `router_settings` 下会导致 Router 构造函数忽略该键（`Key 'cache' is not a valid argument for Router.__init__()`），Redis 从未被初始化。此问题在 5 月 12 日排查后被修正，详见"后续发现"。

## 时间线

| 时间 (UTC) | 事件 |
|------------|------|
| 05:38 | 用户报告 litellm 所有 endpoint 超时 |
| 05:58 | 重启 litellm deployment（临时恢复，约 1 小时后再次恶化） |
| 06:20 | 升级到 `1.83.14-stable`，测试新版是否修复 Helm Chart 问题 |
| 07:18 | 确认新版 Chart `deployStandalone` 模式仍不设 `DATABASE_URL`；添加 Kustomize patch |
| 07:30 | 推送 patch，验证 `DATABASE_URL` 已注入 Pod env |
| 07:44 | 发现 patch 生效后服务依然不可用 → 排除 DATABASE_URL 假说 |
| | 深入排查：port 4000 全部超时，port 8081 正常 → 定位 event loop 饱和 |
| 07:50 | 推送 `numWorkers: 2` |
| 07:54 | 验证恢复（各 endpoint < 10s） |
| 08:30 | 分析多 worker 状态隔离问题，确认需启用 Redis |
| 08:44 | 推送 `numWorkers: 4` + Redis enabled + cache 配置（commit bc2fd6e） |

## 后续发现（2026-05-12）：Token 消耗激增

5 月 11 日部署多 worker + Redis 后，次日发现 token 消耗数异常激增（请求量从 ~45/天 → ~3755/天 → ~6318/半天）。排查发现三个叠加问题。

### 问题一：`cache: true` 放错位置，Redis 从未初始化

LiteLLM `proxy_server.py` 的 Redis 初始化逻辑在 `_init_cache()`（第 3328 行），由 `litellm_settings` 遍历触发（第 3629 行）：

```python
for key, value in litellm_settings.items():         # ← 遍历 litellm_settings
    if key == "cache" and value is True:             # line 3629
        # 读取 REDIS_HOST/PORT/PASSWORD env vars
        # 创建 RedisCache
        # 附加到 Router
```

commit `8312e49` 将 `cache: true` 和 `enable_redis_auth_cache: true` 放在了 `router_settings` 下。`router_settings` 中的键会经过 `get_valid_args()` 过滤后传给 `Router.__init__()`——`cache` 和 `enable_redis_auth_cache` 不是 Router 的有效参数，被静默丢弃：

```
Key 'cache' is not a valid argument for Router.__init__(). Ignoring this key.
Key 'enable_redis_auth_cache' is not a valid argument for Router.__init__(). Ignoring this key.
```

**后果**：Redis 从未初始化，所有共享状态（cooldown、session affinity、TPM/RPM、spend）仍为 per-worker。

**修复**（commit `2818857`）：将配置移到正确位置：

```diff
 proxy_config:
-  router_settings:
+  litellm_settings:
     cache: true
     enable_redis_auth_cache: true
```

### 问题二：Redis 密码不匹配

修复问题一后重启 pod，发现 pod 的 `REDIS_PASSWORD` 与 Redis 实例实际密码不一致。原因是 Redis StatefulSet 曾被重建（Helm Chart 生成了新密码并更新了 Secret），但 litellm pod 未曾重启，环境变量保留旧值。

验证：
```
Secret 中密码：    FJk3XGV5FD
Pod env 密码：     cr1jBMn6he  ← 错误
→ Redis PING：  FJk3XGV5FD → PONG / cr1jBMn6he → WRONGPASS
```

即使问题一修复，若 pod 未重启，Redis 仍不可达。

### 问题三：自定义 Session Hook 不兼容多 Worker

我们编写了 `configmap-claude-code-session-hook.yaml`，目标是在同一模型有多个上游订阅的场景下，将同一 session 的路由固定在同一个 deployment，避免全量历史消息消耗所有订阅的 token 额度。

#### 原设计（单 worker 有效，多 worker 失效）

```
_pending: dict = {}   # session_id → added_at（per-worker 内存）
_bound: dict = {}     # session_id → bound_at（per-worker 内存）

async_pre_call_hook:
    if session_id in _bound → 设置 metadata["session_id"]
    else → 加入 _pending，不设 metadata（让 LiteLLM 走正常路由）

async_success_call_hook:
    if session_id in _pending → 移入 _bound，预写入 Redis affinity cache
```

**多 worker 下的失效路径**：

```
Worker A: session X 首请求 → _pending (A) → 正常路由 → D1 → 成功
          → _bound (A) → 写 Redis (session X → D1)

Worker B: session X 下次请求 → _bound (B) 为空 → _pending (B)
          → 不设 metadata["session_id"]
          → LiteLLM 内置 DeploymentAffinityCheck 不触发 Redis 查询
          → 正常路由，可能打到 D2 → 全量历史消息再次消耗 token
```

根因：`_pending`/`_bound` 是 Python 类变量，存在于每个 uvicorn worker 的独立进程空间内。Worker A 确认的 session，Worker B 完全不知。

#### LiteLLM 内置 Session Affinity 机制

LiteLLM 有内置的 `DeploymentAffinityCheck`（`router_utils/pre_call_checks/deployment_affinity_check.py`），通过 `session_affinity` in `optional_pre_call_checks` 启用：

1. **`async_filter_deployments`**（路由前）：从 `metadata` 读取 `session_id`，查 Redis 缓存，若命中则过滤到绑定的 deployment
2. **`async_pre_call_deployment_hook`**（路由后、请求前）：将 `session_id → model_id` 写入 Redis

两个步骤都依赖 `metadata["session_id"]` 的存在。我们的原 hook 阻断了这个传递。

#### 新设计（commit `278df07`）：始终传递 session_id

```python
async def async_pre_call_hook(self, ...):
    session_id = self._get_session_id(data)
    if not session_id:
        return data
    # 始终设置，让 LiteLLM 内置机制处理
    data["metadata"]["session_id"] = session_id
    return data

async def async_failure_call_hook(self, ...):
    # 失败时清除 Redis 中的 affinity 缓存
    session_id = self._get_session_id(data)
    if session_id and model:
        await self._clear_affinity(session_id, model)
    return data
```

**路由流程**：

```
首请求 → metadata 有 session_id → DeploymentAffinityCheck 查 Redis → miss
       → 正常路由 (simple-shuffle) → async_pre_call_deployment_hook 写 Redis

后续请求（任何 worker）→ metadata 有 session_id → DeploymentAffinityCheck 查 Redis
                    → hit → 过滤到绑定 deployment → 固定路由
```

移除的组件：`_pending`/`_bound` dict、`_cleanup()`、`async_success_call_hook()`、`_prepopulate_affinity()`。

#### Cache Key 对齐

| 组件 | Cache Key 格式 |
|------|---------------|
| 原 hook `_prepopulate_affinity` | `deployment_affinity:v1:session:{model}:{session_id}` |
| LiteLLM `DeploymentAffinityCheck` | `deployment_affinity:v1:session:{model}:{session_id}` |

两者一致，LiteLLM 内置机制可直接读取原 hook 写入的缓存。新 hook 写入删除也使用相同前缀。

### 修复后验证

```bash
# Redis 连接正常
redis-cli PING → PONG

# Session affinity 生效
redis-cli KEYS "deployment_affinity:*"
→ deployment_affinity:v1:session:plan/zhipu/glm-5.1/anthropic:{uuid}
→ deployment_affinity:v1:session:plan/zhipu/glm-5.1/anthropic:{uuid}

# 值格式
redis-cli GET "..."
→ {"model_id": "0f2714e3f3625..."}
TTL: 3567s (≈ 3600)
```

## 经验教训

1. **流式 LLM 场景必须 `numWorkers >= 2`**。流式连接长时间占用 event loop，单 worker 下所有请求排队。`numWorkers` 默认值 1 适合开发环境但不适合生产。

2. **多 worker 必须先启用 Redis，且配置必须放在 `litellm_settings` 下**。无 Redis 时 Router 的 cooldown、session affinity、TPM/RPM 等状态全部 per-worker，功能严重退化。`cache: true` 放在 `router_settings` 下会被静默忽略——LiteLLM 的 proxy_server.py 从 `litellm_settings` 读取该配置，Router 构造函数不接受 `cache` 参数。

3. **`SEPARATE_HEALTH_APP` 是双刃剑**。它让健康检查不受主代理阻塞影响，但也使 K8s 无法感知主代理故障。建议对 port 4000 添加 blackbox 响应时间监控，或使用 Service Monitor 单独探测主代理 `/health/readiness`。

4. **排查时区分症状和根因**。Prisma 错误在本次是 event loop 饱和的下游症状，而非独立故障。与 4-29 事故对比：4-29 时 event loop 空闲、API routing 正常，Prisma engine 确实死亡；本次 event loop 先被占满，所有 async 操作（包括 Prisma 通信）随之失败。

5. **`envVars` 的副作用**：Helm values 中的 `envVars` 同时注入 Deployment 和 Migration Job。对于仅需作用于 Deployment 的环境变量，Kustomize patch 更安全。

6. **自定义 Callback 的状态不能依赖进程内内存**。多 worker 环境下每个 worker 是独立进程，类变量（`_pending`/`_bound`）仅对应当前 worker。需要跨 worker 共享状态时应使用 Redis 等外部存储，或借助 LiteLLM 内置的 Redis-backed 机制（如 `DeploymentAffinityCheck`）。

7. **验证 Redis 是否真正在运行**。仅仅在配置中声明 `cache: true` 不够。应检查：启动日志是否有 `Setting Cache on Proxy`、`redis-cli DBSIZE` 是否 > 0、是否创建了 `deployment_affinity:*` 等预期 key。K8S Secret 更新后 pod 不会自动重启，环境变量保持旧值，可能导致密码不匹配。
