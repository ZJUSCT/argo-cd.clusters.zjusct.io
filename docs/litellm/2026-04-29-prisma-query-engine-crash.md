# 2026-04-29 LiteLLM Dashboard 无法登录：Prisma Query Engine 进程死亡

## 现象

- LiteLLM 代理服务（API 路由转发）正常工作
- 访问 Dashboard 登录时报错：`Unexpected token 'u', "upstream c"... is not valid JSON`

## 错误溯源

### 完整调用链

```
Browser → Envoy Gateway → LiteLLM Pod (port 4000) → Prisma Query Engine → PostgreSQL
                                                          ↑ 已死亡
```

### 第一层：前端报错

```
Unexpected token 'u', "upstream c"... is not valid JSON
```

前端 JS 调用 `/login` API，期望返回 JSON，实际收到的是 Envoy Gateway 的 HTML 错误页：

```
upstream connect error or disconnect/reset before headers. reset reason: ...
```

**原因**：LiteLLM 后端返回 500，Envoy 拦截后返回了自己的错误页 HTML。

### 第二层：Prisma 连接错误

LiteLLM Pod 日志中大量出现：

```
WARNING: prisma-query-engine PID 0 is dead; reconnecting.
ERROR: Prisma DB reconnect failed (194 consecutive). reason=auth_get_key_object_lookup_failure
ERROR: Giving up get_data(...) after 3 tries (prisma.errors.ClientNotConnectedError)
```

LiteLLM 启动时 Prisma query engine（Rust 编写的独立二进制进程）正常运行，之后该进程死亡（PID 变为 0），且所有自动重连尝试均失败。

### 第三层：Database URL 缺失

```
# 容器内环境变量检查
DATABASE_URL=NOT SET
DATABASE_HOST=litellm-postgresql
DATABASE_USERNAME=litellm
DATABASE_PASSWORD=***
DATABASE_NAME=litellm
```

Prisma schema (`schema.prisma`) 定义 datasource 依赖 `env("DATABASE_URL")`：

```prisma
datasource client {
  provider = "postgresql"
  url      = env("DATABASE_URL")
}
```

`DATABASE_URL` 未被显式设置。LiteLLM 程序内部在启动时可能从分片变量（`DATABASE_HOST / DATABASE_USERNAME / DATABASE_PASSWORD / DATABASE_NAME`）拼接后传给 PrismaClient，但 Prisma query engine 进程死亡后，重连逻辑未能重新建立连接。

### 第四层：PostgreSQL（正常）

PostgreSQL Pod 自始至终运行正常，无重启记录：

| 检查项 | 状态 |
|--------|------|
| Pod Status | Running, Ready |
| Restart Count | 0 |
| Liveness (`pg_isready`) | 通过 |
| Readiness | 通过 |

TCP 连通性从 LiteLLM Pod 到 PostgreSQL Pod 也正常（DNS 解析成功，5432 端口可达）。

PostgreSQL 日志中有少量 `Connection reset by peer` 和 `unexpected EOF`，但这是 LiteLLM 侧 Prisma 进程死亡导致的被动断连，不是 PostgreSQL 自身故障。

## 根因

**PostgreSQL Pod 重启导致 Prisma Query Engine 断连且无法自动恢复。**

### 触发事件

Commit [`90c1642`](https://github.com/zjusct/ops/commit/90c1642) 将 PostgreSQL 镜像 tag 从 `16.2.0-debian-12-r6` 改为 `latest`：

```diff
 postgresql:
+  image:
+    tag: "latest"
   primary:
     persistence:
       storageClass: openebs-hostpath
```

原因：Bitnami 从 Docker Hub 移除了旧镜像，Argo CD 在同步时因镜像拉取失败，被迫使用 `latest` tag。

### 时间链

```
01:56  commit 90c1642 提交（postgresql image tag → latest）
  ↓    ArgoCD 同步
02:14  PostgreSQL Pod 用新镜像重建，IP 变更
  ↓    旧 PostgreSQL Pod 终止 → LiteLLM 侧的 Prisma 连接被 RST
  ↓    Prisma Query Engine 检测到连接断开，进程退出（PID → 0）
  ↓    LiteLLM 开始尝试重连 Prisma
  ↓    重连失败（DATABASE_URL 未设置，Prisma 无法重新初始化 query engine）
  ↓    累计失败 194 次后放弃
12:39  用户发现 Dashboard 登录失败
```

### 为什么重连失败

Prisma Client Python 的 query engine 是一个独立的 Rust 二进制进程，由 Python 客户端 spawn 并通过 HTTP 通信。当 PostgreSQL Pod 重启导致 TCP 连接被 RST 后：

1. Query engine 检测到连接断开，进程退出（日志：`prisma-query-engine PID 0 is dead`）
2. LiteLLM 内置了重连逻辑，但调用 `prisma.connect()` 需要 `DATABASE_URL` 环境变量来重新启动 query engine
3. 当前部署仅设置了分片变量（`DATABASE_HOST` / `DATABASE_USERNAME` / `DATABASE_PASSWORD` / `DATABASE_NAME`），**`DATABASE_URL` 未设置**
4. 重连逻辑反复失败，累计 194 次后彻底放弃

### 为什么 Kubernetes 层面没有异常

- query engine 是容器内的子进程，其退出不会导致容器退出
- Pod 状态始终为 Running，无 OOMKilled 事件，无重启
- 就绪探针（`/health/readiness`）可能仅检查 HTTP 端口，不检查 DB 连接

## 解决方案

**重启 LiteLLM Pod**，让 Prisma query engine 随容器重新启动：

```bash
kubectl -n litellm rollout restart deployment/litellm
```

重启后 Prisma query engine 重新初始化并成功连接数据库，Dashboard 登录恢复。

## 时间线

| 时间 (CST) | 事件 |
|-------------|------|
| 2026-04-29 01:56 | Commit `90c1642`：`postgresql.image.tag` 改为 `latest`（因 Bitnami 移除旧镜像） |
| 2026-04-29 02:14 | ArgoCD 同步，PostgreSQL Pod 用新镜像重建 |
| 02:14 起 | LiteLLM 的 Prisma Query Engine 断连死亡，重连失败（累计 194 次） |
| 2026-04-29 ~12:39 | 收到 Dashboard 登录失败报告，开始排查 |
| ~20:50 | 执行 `kubectl -n litellm rollout restart deployment/litellm`，服务恢复 |

## 后续建议

1. **不要在 PostgreSQL 中使用 `latest` tag**（治本）：在 Helm values 中锁定明确的 PostgreSQL 镜像 tag，避免镜像变更触发意外重建
2. **PostgreSQL 重建后联动重启 LiteLLM**：PostgreSQL Pod 重建后 LiteLLM 需要同步重启，可考虑用 ArgoCD sync-wave 或 post-sync hook 实现
3. **设置 `DATABASE_URL` 环境变量**（增强容错）：在 Helm values 中显式设置完整连接字符串 `postgresql://litellm:<password>@litellm-postgresql:5432/litellm`，确保 Prisma 重连逻辑能正常工作
4. **增加就绪探针 DB 检查**：在 `/health/readiness` 中加入数据库连通性检查，当 Prisma 不可用时自动将 Pod 标记为未就绪，由 Envoy Gateway 自动切流
