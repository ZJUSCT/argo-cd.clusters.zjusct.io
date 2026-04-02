# TODO

## LiteLLM — Responses API Bridge Workaround

- **Issue:** LiteLLM does not bridge `/v1/responses` to `/v1/chat/completions` for `openai/`-prefixed models with custom `api_base`. Upstream providers return 404.
- **GitHub Issue:** [BerriAI/litellm#23716](https://github.com/BerriAI/litellm/issues/23716) — Allow openai compatible models with custom api_base to opt-in to /responses bridge
- **Workaround:** Changed `custom_llm_provider: openai` to `custom_llm_provider: hosted_vllm` for all models with custom `api_base` in `production/litellm/values/litellm-helm-0.1.837.yaml`. This triggers LiteLLM's built-in bridge automatically.
- **Affected models:** All 11 OpenAI-API models (opencode-go, kimi, minimax, zhipu). Anthropic-API models are unaffected.
- **Revert:** Once litellm#23716 is resolved and we upgrade to a version with native support, revert `custom_llm_provider` back to `openai` for all affected models.

## Packer: SSSD Timeout

https://oneuptime.com/blog/post/2026-03-04-configure-sssd-caching-policies-offline-authentication-rhel/view

- [ ] Configure SSSD caching
- [ ] IPA Auto enrollment

## Squid: NVIDIA APT Repo Cache

- [x] Fix: https://github.com/ZJUSCT/squid/commit/ea38b6fcaee5902e7310a6072cf40e3365de1e88
- [ ] Submit patch to upstream: https://bugs.squid-cache.org/show_bug.cgi?id=5538
