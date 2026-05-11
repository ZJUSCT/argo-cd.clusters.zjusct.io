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

同时启用 Router 缓存与认证缓存：

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

### 最终配置变更

```diff
-replicaCount: 1
-# numWorkers: 2
+numWorkers: 4

 proxy_config:
   litellm_settings:
+    cache: true
+    enable_redis_auth_cache: true

 redis:
-  enabled: false
+  enabled: true
+  architecture: standalone
```

同时移除了不必要的 `DATABASE_URL` Kustomize patch。

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

## 经验教训

1. **流式 LLM 场景必须 `numWorkers >= 2`**。流式连接长时间占用 event loop，单 worker 下所有请求排队。`numWorkers` 默认值 1 适合开发环境但不适合生产。

2. **多 worker 必须先启用 Redis**。无 Redis 时 Router 的 cooldown、session affinity、TPM/RPM 等状态全部 per-worker，功能严重退化。

3. **`SEPARATE_HEALTH_APP` 是双刃剑**。它让健康检查不受主代理阻塞影响，但也使 K8s 无法感知主代理故障。建议对 port 4000 添加 blackbox 响应时间监控，或使用 Service Monitor 单独探测主代理 `/health/readiness`。

4. **排查时区分症状和根因**。Prisma 错误在本次是 event loop 饱和的下游症状，而非独立故障。与 4-29 事故对比：4-29 时 event loop 空闲、API routing 正常，Prisma engine 确实死亡；本次 event loop 先被占满，所有 async 操作（包括 Prisma 通信）随之失败。

5. **`envVars` 的副作用**：Helm values 中的 `envVars` 同时注入 Deployment 和 Migration Job。对于仅需作用于 Deployment 的环境变量，Kustomize patch 更安全。
