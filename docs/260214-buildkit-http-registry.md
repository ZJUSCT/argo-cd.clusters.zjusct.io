# BuildKit HTTP Registry with Harbor - Complete Guide

**Problem**: Configure BuildKit to use insecure (HTTP) registry for push, pull, and cache operations with Harbor's internal HTTP-only endpoint.

**Status**: ⚠️ **DEPRECATED** - Migrated to HTTPS via DNS split-horizon

> **Note**: This document describes the HTTP-registry approach which has been deprecated.
> See [docs/migration-to-https-registry.md](migration-to-https-registry.md) for the current HTTPS-based approach
> that uses `harbor.clusters.zjusct.io` via envoy-gateway.

---

## Core Problem

BuildKit needs to push/pull/cache container images to Harbor's internal HTTP-only service (`harbor-core.default.svc.cluster.local:80`). The challenge is that:

1. **buildkitd (daemon)** supports HTTP registries via `http = true` configuration
2. **Image operations** (push/pull/cache) happen in the daemon
3. **Authentication** (token fetch) happens in the CLI client via gRPC session
4. **Harbor returns realm URLs** with wrong protocol in `Www-Authenticate` headers

This architectural split causes authentication to fail even when registry operations are correctly configured for HTTP.

---

## Root Cause Analysis

### BuildKit Architecture Split

BuildKit uses a **split architecture** for registry operations:

```
┌─────────────────────────────────────────────────────────────────┐
│ buildctl (CLI Client)                                           │
│  - Fetches auth tokens from realm URL                          │
│  - Uses tracing.DefaultClient (HTTPS only)                     │
│  - NO access to buildkitd.toml config                          │
└─────────────────────────────────────────────────────────────────┘
                             │
                         gRPC Session
                             │
┌─────────────────────────────────────────────────────────────────┐
│ buildkitd (Daemon)                                              │
│  - Reads buildkitd.toml (http = true)                          │
│  - Performs image push/pull/cache operations                    │
│  - Correctly uses HTTP for v2 API endpoints                    │
└─────────────────────────────────────────────────────────────────┘
```

**The Gap**: When Harbor returns `401 Unauthorized` with:
```
Www-Authenticate: Bearer realm="https://harbor-core.../service/token"
```

The **client** fetches the token using the HTTPS URL, but Harbor only serves HTTP, causing "connection refused" on port 443.

**Related Issue**: [moby/buildkit#4458](https://github.com/moby/buildkit/issues/4458) - BuildKit HTTP registry support

---

## The Solution (Two-Part Fix)

### Part 1: Fix Harbor's Realm URL ✅

**Problem**: Harbor returns HTTPS realm URLs even for HTTP requests.

**Root Cause**: Harbor's `tokenSvcURL()` function ([source](https://github.com/goharbor/harbor/blob/main/src/server/middleware/v2auth/auth.go#L118-L140)) matches the request `Host` header against configured `CORE_URL`:

```go
func tokenSvcURL(req *http.Request) (string, error) {
    rawCoreURL := config.InternalCoreURL()  // From CORE_URL env var

    if match(req.Context(), req.Host, rawCoreURL) {
        return getURL(rawCoreURL), nil  // ← Use HTTP if match
    }

    // No match → falls back to external endpoint scheme (HTTPS)
    extEp, err := config.ExtEndpoint()
    if len(req.Host) > 0 {
        l := strings.Split(extEp, "://")
        return getURL(l[0] + "://" + req.Host), nil  // ← HTTPS + FQDN
    }
    return getURL(extEp), nil
}
```

**The Mismatch**:
- ConfigMap had: `CORE_URL=http://harbor-core:80` (short hostname)
- BuildKit uses: `harbor-core.default.svc.cluster.local` (FQDN)
- No match → Falls back to HTTPS

**Fix**: Patch Harbor ConfigMap to use FQDN

```yaml
# production/default/patches/harbor-core-cm-patch.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: harbor-core
  namespace: default
data:
  CORE_URL: "http://harbor-core.default.svc.cluster.local:80"
  TOKEN_SERVICE_URL: "http://harbor-core.default.svc.cluster.local:80/service/token"
```

```yaml
# production/default/kustomization.yaml
patches:
- path: patches/harbor-core-cm-patch.yaml
  target:
    kind: ConfigMap
    name: harbor-core
```

**Result**: Harbor now returns HTTP realm URLs
```
Www-Authenticate: Bearer realm="http://harbor-core.default.svc.cluster.local:80/service/token"
```

**Commit**: `7843655`

**Related Issue**: [goharbor/harbor#12364](https://github.com/goharbor/harbor/issues/12364) - Harbor HTTP realm URL configuration

---

### Part 2: Fix BuildKit Credentials ✅

**Problem**: BuildKit cannot find Docker credentials for authentication.

**Root Cause**: Kubernetes mounts docker-registry secrets with key `.dockerconfigjson`, but BuildKit expects `$DOCKER_CONFIG/config.json`.

**Fix**: Copy secret to correct location before build

```yaml
# dev/dev-tekton/resources/03-task-buildkit.yaml
env:
- name: DOCKER_CONFIG
  value: /tekton/home/.docker
script: |
  # BuildKit expects config.json, but Kubernetes mounts .dockerconfigjson
  mkdir -p /tekton/home/.docker
  cp /workspace/dockerconfig/.dockerconfigjson /tekton/home/.docker/config.json

  buildctl build \
    --output type=image,name=...,push=true,registry.insecure=true \
    --import-cache type=registry,ref=...,registry.insecure=true
```

**Commit**: `0711b37`

---

## BuildKit Configuration

### buildkitd.toml (Daemon Config)

```toml
# dev/dev-buildkitd/buildkitd-config.yaml
debug = true

[registry."harbor-core.default.svc.cluster.local"]
  http = true      # Use HTTP protocol for v2 API
  insecure = true  # Enable httpFallback transport for HTTPS→HTTP fallback
```

**Key Points**:
- `http = true` sets `Scheme = "http"` on registry host ✅
- `insecure = true` enables `httpFallback` transport wrapper
- Combined: Daemon uses HTTP but can handle HTTPS challenges

---

## Authentication Flow (Fixed)

1. **BuildKit Daemon** → `GET http://harbor-core.../v2/.../blobs/sha256:...`
   - Uses HTTP (from `http = true` config)

2. **Harbor** → Returns `401 Unauthorized`
   ```
   Www-Authenticate: Bearer realm="http://harbor-core.default.svc.cluster.local:80/service/token"
   ```
   - ✅ HTTP realm URL (after FQDN patch)

3. **BuildKit Client** → `GET http://harbor-core.../service/token`
   - Uses realm URL as-is
   - Sends credentials from `$DOCKER_CONFIG/config.json` ✅

4. **Harbor Token Service** → Returns Bearer token

5. **BuildKit Daemon** → Retries with `Authorization: Bearer <token>`
   - ✅ Success! Push completes

---

## Failed Approaches (For Reference)

### ❌ Attempt 1: Combined Workaround Without Harbor Fix
**Config**: `http=true` + `insecure=true` + `BUILDKIT_NO_CLIENT_TOKEN=1`
**Result**: Failed - Harbor still returned HTTPS realm URLs
**Commits**: 287550d, 8940cd8 (reverted)

### ❌ Attempt 2: Enable Harbor Internal TLS
**Approach**: Make Harbor serve HTTPS to match token URLs
**Result**: Harbor Helm chart v1.18.2 has validation bugs with `internalTLS.enabled=true`
**Commit**: 4676df0 (reverted in ea97aaf)

### ❌ Attempt 3: Use External HTTPS Endpoint
**Approach**: Use `harbor.clusters.zjusct.io:443` (LoadBalancer)
**Result**: Pods cannot access LoadBalancer IPs (cluster networking policy)

---

## Verification

### Test BuildKit Push

```bash
kubectl create -f dev/dev-tekton/resources/06-pipelinerun-ubuntu-test.yaml
# Result: build-ubuntu-run-8c2m8 → Succeeded ✅
```

### Verify Image in Harbor

```bash
curl -u "robot\$tekton:PASSWORD" \
  http://harbor-core.default.svc.cluster.local/v2/library/ubuntu-curl/tags/list
# Result: {"name":"library/ubuntu-curl","tags":["latest"]} ✅
```

### Check Harbor Realm URL

```bash
curl -I http://harbor-core.default.svc.cluster.local/v2/
# Www-Authenticate: Bearer realm="http://harbor-core.default.svc.cluster.local:80/service/token" ✅
```

---

## Side Effects and Safety

**Q**: Does the CORE_URL FQDN patch affect Harbor internal services?

**A**: NO ✅ - All Harbor services remain healthy.

**Why Safe**:
1. Internal services (jobservice, registry) use short hostname `harbor-core`
2. They now get HTTPS realm URLs (no match with FQDN CORE_URL)
3. BUT: They use internal REST APIs (`/api/v2.0/*`), NOT Docker v2 API (`/v2/*`)
4. They authenticate with `CORE_SECRET`, NOT Bearer tokens from `Www-Authenticate`

**Verified**: All Harbor pods running healthy after patch:
- harbor-core, harbor-jobservice, harbor-registry, harbor-portal, harbor-database, harbor-redis, harbor-trivy

---

## Key Learnings

1. **BuildKit `http = true` is incomplete**: Works for v2 API but not for client-side token auth
2. **Harbor realm URLs are dynamic**: Constructed from request Host header + CORE_URL matching
3. **Kubernetes secret keys matter**: `.dockerconfigjson` vs `config.json` mismatch
4. **Source code investigation pays off**: Reading Harbor source revealed the exact match logic

---

## Configuration Files

### Modified Files
1. `production/default/patches/harbor-core-cm-patch.yaml` (NEW)
2. `production/default/kustomization.yaml` (patch added)
3. `dev/dev-buildkitd/buildkitd-config.yaml` (`http=true` + `insecure=true`)
4. `dev/dev-tekton/resources/03-task-buildkit.yaml` (docker config copy script)

### Git Commits
- `7843655` - Harbor CORE_URL FQDN patch
- `0711b37` - BuildKit docker credentials fix
- `d593217` - Technical documentation
- `139bef0` - Success summary

---

## Related GitHub Issues

- [moby/buildkit#4458](https://github.com/moby/buildkit/issues/4458) - BuildKit HTTP registry support
- [goharbor/harbor#12364](https://github.com/goharbor/harbor/issues/12364) - Harbor HTTP authentication realm URLs

---

## Alternative Solutions (Not Used)

### Option: Switch to Kaniko
- Has documented HTTP registry support
- Simpler architecture (no daemon)
- Trade-off: Lose BuildKit features (remote cache, multi-platform builds)

### Option: Fix Cluster Networking
- Enable pod-to-LoadBalancer access
- Use external `harbor.clusters.zjusct.io:443` (standard HTTPS)
- Requires infrastructure changes

### Option: Upstream BuildKit Fix
- Propagate `http = true` config to client-side auth provider
- Or rewrite realm URLs on daemon side before delegation
- Complexity: Moderate - would benefit entire community

---

## Summary

**The Problem**: BuildKit's split architecture (daemon does registry ops, client does auth) combined with Harbor's dynamic realm URL construction caused HTTPS connections to HTTP-only services.

**The Solution**: Two-part fix:
1. Patch Harbor CORE_URL to use FQDN → Harbor returns HTTP realm URLs
2. Copy docker credentials to correct location → BuildKit can authenticate

**Result**: ✅ BuildKit successfully pushes/pulls/caches images to Harbor's internal HTTP endpoint.

**Status**: Fully resolved and production-ready.
