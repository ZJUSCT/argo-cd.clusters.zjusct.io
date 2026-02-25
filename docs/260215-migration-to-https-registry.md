# Migration to HTTPS Registry via DNS Split-Horizon

**Date**: 2026-02-15

**Status**: ✅ **COMPLETED**

---

## Summary

Migrated BuildKit and Tekton pipelines from using Harbor's internal HTTP endpoint to the external HTTPS endpoint via DNS split-horizon.

---

## Problem

When using Cilium with DSR (Direct Server Return), pods cannot connect to LoadBalancer services via the external IP from within the cluster. This is a known limitation: [cilium/cilium#39198](https://github.com/cilium/cilium/issues/39198).

The previous workaround used Harbor's internal HTTP-only service with complex configuration. DNS split-horizon provides a cleaner solution.

---

## Solution

Use CoreDNS rewrite to resolve the external hostname to the gateway proxy's ClusterIP, allowing pods to connect via internal network paths.

### 1. Create Envoy Proxy Alias Service

Envoy Gateway auto-generates service names with hashes. Create a stable alias:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: envoy-proxy
  namespace: envoy-gateway
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/component: proxy
    gateway.envoyproxy.io/owning-gateway-name: envoy-gateway
    gateway.envoyproxy.io/owning-gateway-namespace: envoy-gateway
  ports:
  - name: http
    port: 80
    targetPort: 10080
  - name: https
    port: 443
    targetPort: 10443
```

### 2. Configure CoreDNS Rewrite

```yaml
- name: rewrite
  parameters: stop
  configBlock: |-
    name exact harbor.example.com envoy-proxy.envoy-gateway.svc.cluster.local answer auto
```

### 3. Simplify BuildKit Configuration

No special registry configuration needed when using HTTPS with public CA certificates:

```toml
debug = true
# No registry config needed - uses public CA
```

### 4. Remove Insecure Flags

```yaml
# Before
--output type=image,name=$(params.IMAGE),push=true,registry.insecure=true

# After
--output type-image,name=$(params.IMAGE),push=true
```

---

## Architecture

```
Pod → CoreDNS (rewrite) → envoy-proxy ClusterIP → Envoy Gateway → Harbor
```

1. Pod resolves `harbor.example.com`
2. CoreDNS rewrites to `envoy-proxy.envoy-gateway.svc.cluster.local`
3. Traffic goes to envoy proxy ClusterIP (not external LB)
4. Envoy routes to Harbor backend

---

## Benefits

- **Standard HTTPS**: Public CA certificates, no insecure flags
- **Simpler Configuration**: No HTTP registry workarounds
- **Consistency**: Same hostname works inside and outside the cluster
