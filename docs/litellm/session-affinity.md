# LiteLLM Claude Code Session Affinity

## 背景

同一 model group（如 `plan/zhipu/glm-5-turbo`）配置了多个 API Key 对应多个 deployment。LiteLLM 默认 `simple-shuffle` 随机路由，导致同一 Claude Code 会话的请求被分发到不同 API Key，而上游 provider（智谱 GLM）按 Key 隔离 KV Cache，跨 Key 路由使 prompt cache 命中率接近 0。

## 实现原理

Claude Code 每次请求自动携带 `X-Claude-Code-Session-Id` header。通过自定义 LiteLLM 插件将该 header 值映射为 `metadata["session_id"]`，配合 LiteLLM 内置的 `session_affinity` 路由检查，实现同一会话粘性路由到同一 deployment（同一 API Key）。

请求链路：

```
Claude Code 请求（X-Claude-Code-Session-Id: <uuid>）
  -> LiteLLM Proxy 接收
  -> async_pre_call_hook（自定义插件）
       读取 data["proxy_server_request"]["headers"]["x-claude-code-session-id"]
       写入 data["metadata"]["session_id"]
  -> DeploymentAffinityCheck.async_filter_deployments
       读取 metadata["session_id"]，查询内存 cache
       命中 -> 固定路由到同一 deployment
       未命中 -> 正常负载均衡，缓存结果（TTL 1h）
```

## 改动文件

### 1. ConfigMap — 插件代码

`production/litellm/resources/configmap-claude-code-session-hook.yaml`

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: litellm-claude-code-session-hook
  namespace: litellm
data:
  claude_code_session.py: |
    from litellm.integrations.custom_logger import CustomLogger

    class ClaudeCodeSessionMapper(CustomLogger):
        CLAUDE_CODE_SESSION_HEADER = "x-claude-code-session-id"

        async def async_pre_call_hook(
            self, user_api_key_dict, cache, data, call_type
        ):
            headers = (data.get("proxy_server_request") or {}).get("headers", {})
            session_id = headers.get(self.CLAUDE_CODE_SESSION_HEADER)
            if session_id:
                if "metadata" not in data:
                    data["metadata"] = {}
                data["metadata"]["session_id"] = session_id
            return data

    proxy_handler_instance = ClaudeCodeSessionMapper()
```

逻辑说明：
- 继承 `CustomLogger` 基类，实现 `async_pre_call_hook` 方法
- 从 `data["proxy_server_request"]["headers"]` 读取原始请求 header（LiteLLM 已统一转为小写）
- 将 session ID 写入 `data["metadata"]["session_id"]`，供 `DeploymentAffinityCheck` 读取
- 返回修改后的 `data` 字典即可生效
- 模块级变量 `proxy_handler_instance` 是 LiteLLM 通过 `get_instance_fn()` 加载回调时的约定入口

### 2. kustomization.yaml — 引用 ConfigMap

```yaml
resources:
  - resources/configmap-claude-code-session-hook.yaml  # 新增
```

### 3. values/litellm-helm-1.82.3.yaml — 三处修改

**注册插件（callbacks 列表）：**

```yaml
litellm_settings:
  callbacks: [ "otel", "prometheus", "hooks.claude_code_session.proxy_handler_instance" ]
```

LiteLLM 的 `get_instance_fn()` 以 `.` 分隔解析模块路径：`hooks.claude_code_session.proxy_handler_instance` 会被解析为 `{config_dir}/hooks/claude_code_session.py` 模块中的 `proxy_handler_instance` 对象。因此挂载路径必须是 `/etc/litellm/hooks`（config.yaml 所在目录的子目录），而非 `/app/hooks`。

**启用 session affinity（router_settings）：**

```yaml
router_settings:
  routing_strategy: simple-shuffle
  optional_pre_call_checks:
    - session_affinity
  deployment_affinity_ttl_seconds: 3600
```

- `simple-shuffle`：新会话随机分配到不同 deployment，实现负载均衡
- `session_affinity`：已有会话粘性路由到同一 deployment
- `deployment_affinity_ttl_seconds: 3600`：亲和关系缓存 1 小时，TTL 到期后下次请求重新负载均衡

**挂载 ConfigMap（volumes + volumeMounts）：**

```yaml
volumes:
  - name: claude-code-session-hook
    configMap:
      name: litellm-claude-code-session-hook

volumeMounts:
  - name: claude-code-session-hook
    mountPath: /etc/litellm/hooks
    readOnly: true
```

## 关键技术点

- **回调注册方式**：必须使用 `callbacks` 列表中带 `.` 的路径字符串，由 `get_instance_fn()` 通过 `importlib` 加载。`custom_callback_module` 不是有效配置项
- **挂载路径**：`get_instance_fn()` 以 `config.yaml` 所在目录（`/etc/litellm/`）为基准解析模块路径，挂载点必须是该目录的子目录
- **双路径兼容**：OpenAI 路径（`/chat/completions`）的 metadata 变量名为 `metadata`，Anthropic 路径（`/v1/messages`）为 `litellm_metadata`。`DeploymentAffinityCheck._iter_metadata_dicts` 会同时检查两个 key，因此插件只需设置 `data["metadata"]["session_id"]`
- **验证依据**：查数据库 `LiteLLM_SpendLogs.model_id` 列（deployment 哈希）判断路由结果，不要依赖 `session_id` 列（该列由 LiteLLM 自动生成 UUID，不反映 hook 设置的值）
- **Redis**：当前 `replicaCount: 1`，session affinity 使用内存 cache，Pod 重启后缓存丢失但下次请求会重新绑定。若扩容多副本需启用 Redis

## 测试

最简单的测试方式应该是直接在claude code终端中发请求，然后去我们的litellm的web ui中查看对应的请求被路由到的后端。是否出现了同一个session被路由到同一个订阅，不同session有很大概率被路由到不同订阅。
