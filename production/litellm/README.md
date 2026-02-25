# LiteLLM Configuration Guide

LiteLLM acts as an LLM proxy service that centrally manages API access to multiple LLM providers.

## Configuration File Locations

* **ConfigMap**: `resources/configmap.yaml` – contains the `config.yaml` configuration
* **Helm Values**: `values/` – Helm chart configuration
* **Kustomization**: `kustomization.yaml` – Kustomize configuration

## Key Points for Model Configuration

### 1. Adding OpenAI-Compatible Providers (Generic)

For providers that are not built into LiteLLM (such as SiliconFlow, Bailian, etc.), you **must** add the `openai/` prefix to the `litellm_params.model` field:

```yaml
model_list:
  - model_name: siliconflow/GLM-4.7
    litellm_params:
      model: openai/Pro/zai-org/GLM-4.7    # openai/ prefix is required
      api_base: https://api.siliconflow.cn
      api_key: sk-...

  - model_name: bailian/qwen3-max
    litellm_params:
      model: openai/qwen3-max-2026-01-23   # openai/ prefix is required
      api_base: https://dashscope.aliyuncs.com/compatible-mode/v1
      api_key: sk-...
```

**Rationale**: LiteLLM determines the provider by parsing the `model` field via the `get_llm_provider()` function. For model names that are not in the built-in model list, a `<provider>/` prefix is required. `openai` is a built-in provider that triggers the OpenAI-compatible routing logic; at runtime, the `api_base` parameter redirects requests to the correct endpoint.

### 2. Using Built-in Volcengine (火山引擎) Provider

Volcengine is a built-in provider in LiteLLM with special handling for Volcengine-specific features like the `thinking` parameter.

#### Configuration

```yaml
model_list:
  - model_name: volcengine/doubao-seed-2.0-code
    litellm_params:
      model: volcengine/doubao-seed-2.0-code  # Use volcengine/ prefix
      api_key: your-volcengine-api-key
      api_base: https://ark.cn-beijing.volces.com/api/coding/v3  # Required for custom endpoints
      thinking: {"type": "disabled"}  # Volcengine-specific parameter
      tools:
        web_search: 1
```

#### Key Differences from Generic OpenAI-Compatible Provider

| Feature | `volcengine/` Provider | Generic `openai/` Provider |
|---------|-------------------------|-----------------------------|
| Default Base URL | `https://ark.cn-beijing.volces.com/api/v3` | `https://api.openai.com` |
| `thinking` Parameter | Supported natively | Not supported (use `extra_body`) |
| Environment Variables | `ARK_API_KEY`, `VOLCENGINE_API_KEY` | `OPENAI_API_KEY` |

### 3. Using Known Model Names (Anthropic-Compatible)

If the model name exists in LiteLLM’s model registry (for example, `claude-sonnet-4-5`), you can omit the prefix, but you must override the default endpoint using `api_base`:

```yaml
model_list:
  - model_name: ohmygpt/claude-sonnet-4-5
    litellm_params:
      model: claude-sonnet-4-5              # Anthropic model name, no prefix required
      api_base: https://apic1.ohmycdn.com   # override the default Anthropic API endpoint
      api_key: sk-...
```

#### How LiteLLM Detects Anthropic-Compatible Providers

LiteLLM uses multiple methods to detect Anthropic models:

1. **Explicit `custom_llm_provider: "anthropic"`**
2. **Model is in `litellm.anthropic_models` list** (contains all known Claude models)
3. **Fallback**: Model name contains "claude" (case-insensitive)

**Note**: You don't *have to* use a "claude-" prefix. You can explicitly set `custom_llm_provider: "anthropic"` in your `litellm_params` even if the model name doesn't start with "claude-".

## Auto Router Configuration

LiteLLM’s auto router is based on semantic similarity routing and differs from OpenRouter’s `/auto`:

|                        | OpenRouter `/auto`                  | LiteLLM auto router                                               |
| ---------------------- | ----------------------------------- | ----------------------------------------------------------------- |
| Routing logic          | Cost / quality scoring              | Semantic similarity to predefined example phrases                 |
| Configuration required | None                                | Example phrases must be defined per model                         |
| Use cases              | Automatically select the best model | Route by topic/intent (e.g., coding → Model A, writing → Model B) |

### Declarative Configuration

Use the `auto_router_config` parameter to inline the configuration in `config.yaml`:

```yaml
model_list:
  # Embedding model (required by auto router)
  - model_name: embedding-model
    litellm_params:
      model: openai/BAAI/bge-m3
      api_base: https://api.siliconflow.cn
      api_key: sk-...

  # Target models
  - model_name: claude-model
    litellm_params:
      model: claude-sonnet-4-5
      api_base: ...
      api_key: ...

  - model_name: chinese-model
    litellm_params:
      model: openai/qwen-model
      api_base: ...
      api_key: ...

  # Auto router
  - model_name: auto
    litellm_params:
      model: auto_router/auto
      auto_router_default_model: claude-model        # fallback model when no route matches
      auto_router_embedding_model: embedding-model   # used to compute semantic similarity
      auto_router_config: >-
        {
          "routes": [
            {
              "name": "chinese-model",
              "utterances": [
                "用中文回答",
                "请用中文",
                "帮我写一段中文"
              ],
              "description": "Chinese language requests",
              "score_threshold": 0.6
            },
            {
              "name": "claude-model",
              "utterances": [
                "write code for",
                "debug this function",
                "explain this algorithm"
              ],
              "description": "Coding tasks",
              "score_threshold": 0.5
            }
          ]
        }
```

**Key parameters**:

* `model`: must start with `auto_router/`
* `auto_router_config`: JSON string; use YAML’s `>-` folded block scalar for readability
* `routes[].name`: must exactly match a `model_name` in `model_list`
* `routes[].utterances`: list of example phrases for semantic matching
* `routes[].score_threshold`: minimum similarity threshold (0–1)
* `auto_router_default_model`: fallback model when no route matches

**How it works**:

1. When a request arrives, LiteLLM uses `auto_router_embedding_model` to generate embeddings for the input message
2. It computes semantic similarity between the input and each route’s `utterances`
3. If a route’s similarity exceeds `score_threshold`, the request is routed to the model specified by `name`
4. If no route matches, `auto_router_default_model` is used

## Configuration Hot Reloading

LiteLLM proxy **does not support** automatic hot reloading of the `config.yaml` file. After modifying a ConfigMap, you must restart the Pod:

```bash
kubectl rollout restart deployment litellm -n litellm
```

**Components that support hot reloading** (via database coordination, 30-second polling interval):

* Model cost map (`/reload/model_cost_map`)
* Anthropic beta headers (`/reload/anthropic_beta_headers`)
* Database-stored configuration (models added via Web UI or API)

## Troubleshooting

### Pod `CrashLoopBackOff`

Check logs:

```bash
kubectl logs -n litellm <pod-name> --previous
```

Common errors:

1. **`TypeError: argument of type 'NoneType' is not iterable`**
   * Cause: `model_info:` is empty
   * Fix: remove the empty `model_info:` key

2. **`BadRequestError: LLM Provider NOT provided`**
   * Cause: model name is unrecognized and no provider prefix is used
   * Fix: add the `openai/` prefix to `litellm_params.model`

3. **`Unsupported provider - <provider>`**
   * Cause: the provider is not in LiteLLM’s `provider_list` or `providers.json`
   * Fix: use the `openai/` prefix as a generic OpenAI-compatible provider

### Model Not Showing in the UI

1. Check whether the Pod is Ready: `kubectl get pods -n litellm`
2. If the new Pod is not Ready, the old Pod may still be serving traffic, and the UI will show the old configuration
3. Fix configuration errors and wait for the new Pod to start and become Ready

### Validate Configuration

Validate the Kustomize output before applying:

```bash
kubectl kustomize --enable-helm --load-restrictor=LoadRestrictionsNone production/litellm
```

## References

* LiteLLM source code: `tmp/litellm/`
* Adding OpenAI-compatible providers: `tmp/litellm/docs/my-website/docs/contributing/adding_openai_compatible_providers.md`
* Proxy configuration: `tmp/litellm/docs/my-website/docs/proxy/configs.md`
* Auto routing: `tmp/litellm/docs/my-website/docs/proxy/auto_routing.md`
* Provider routing logic: `tmp/litellm/litellm/litellm_core_utils/get_llm_provider_logic.py`
* Volcengine provider implementation: `tmp/litellm/litellm/llms/volcengine/`
