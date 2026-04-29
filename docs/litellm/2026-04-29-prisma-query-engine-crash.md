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

**Prisma Query Engine 进程死亡**。LiteLLM 使用 Prisma Client Python，其底层依赖一个 Rust 编写的 `query-engine` 二进制进程处理所有数据库查询。该进程在运行一段时间后退出（可能原因：内存压力、未捕获的 panic、或被 OOM Killer 处理），导致所有数据库操作（包括 Dashboard 登录验证 token）返回 `ClientNotConnectedError`。

LiteLLM 内置的重连机制未能恢复连接（`DATABASE_URL` 缺失可能阻碍了 Prisma 重新初始化 query engine）。

## 解决方案

**重启 LiteLLM Pod**，让 Prisma query engine 随容器重新启动：

```bash
kubectl -n litellm rollout restart deployment/litellm
```

重启后 Prisma query engine 重新初始化并成功连接数据库，Dashboard 登录恢复。

## 时间线

| 时间 (CST) | 事件 |
|-------------|------|
| 2026-04-29 02:14 | PostgreSQL Pod 启动（Restart Count 0） |
| 02:14 ~ 12:39 期间 | LiteLLM Pod 累计重启 10 次；Prisma query engine 进程死亡后重连失败（累计 194 次） |
| 2026-04-29 ~12:39 | 收到 Dashboard 登录失败报告，开始排查 |
| ~20:50 | 执行 `kubectl -n litellm rollout restart deployment/litellm`，服务恢复 |

## 后续建议

1. **设置 `DATABASE_URL` 环境变量**：在 Helm values 中将 `DATABASE_URL` 显式设为完整的 PostgreSQL 连接字符串（`postgresql://litellm:<password>@litellm-postgresql:5432/litellm`），使 Prisma 重连时有明确的连接目标
2. **配置 Pod 资源限制**：确保 LiteLLM Pod 有足够的 memory limit，避免 OOM Kill
3. **增加就绪探针**：可考虑在 LiteLLM 的就绪探针中加入 DB 连接检查，当 Prisma 不可用时自动将 Pod 标记为未就绪
