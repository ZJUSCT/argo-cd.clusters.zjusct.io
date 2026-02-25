# Argo CD Troubleshooting Guide

## Stuck Resources with Finalizers (2026-02-15)

### Problem
Argo CD application showing "Progressing" health status for extended period (24+ hours), unable to sync properly.

**Specific case**: `envoy-gateway` application stuck with GatewayClass resource in deletion state.

### Symptoms
- Argo CD application health: `Progressing` (stuck for days)
- Argo CD sync status: Can be `Synced` or `OutOfSync`
- Resource has `deletionTimestamp` set
- Resource has finalizers blocking deletion
- Dependent resources still exist that prevent finalizer removal

### Investigation Commands

```bash
# Check Argo CD application status
kubectl get application -n argo-cd <app-name> -o yaml

# Check for stuck resources with deletionTimestamp
kubectl get <resource-type> <resource-name> -o yaml | grep deletionTimestamp

# Check finalizers
kubectl get <resource-type> <resource-name> -o jsonpath='{.metadata.finalizers}'

# Check dependent resources (for GatewayClass example)
kubectl get gateway -A
```

### Root Cause

Resources can get stuck in deletion when:

1. **Finalizer blocks deletion**: Finalizers are used to ensure cleanup of dependent resources
2. **Dependent resources still exist**: The controller managing the finalizer won't remove it until dependencies are cleaned up
3. **Deadlock situation**: Git expects resource to exist, but resource is marked for deletion

**Example**: GatewayClass with finalizer `gateway-exists-finalizer.gateway.networking.k8s.io` cannot be deleted while Gateway resources using it still exist.

### Solution

#### Option 1: Remove Finalizer (Quick Fix)

When a resource is stuck in deletion and you want Argo CD to recreate it fresh:

```bash
# Remove ALL finalizers to allow deletion
kubectl patch <resource-type> <resource-name> --type=json \
  -p='[{"op": "remove", "path": "/metadata/finalizers"}]'

# Example for GatewayClass
kubectl patch gatewayclass envoy-gateway --type=json \
  -p='[{"op": "remove", "path": "/metadata/finalizers"}]'

# Verify deletion
kubectl get <resource-type> <resource-name>
```

After deletion, Argo CD will automatically recreate the resource from Git (if auto-sync is enabled).

#### Option 2: Remove Specific Finalizer

If you only want to remove a specific finalizer:

```bash
# Get current finalizers
kubectl get <resource-type> <resource-name> -o jsonpath='{.metadata.finalizers}'

# Patch to remove specific finalizer
kubectl patch <resource-type> <resource-name> --type=json \
  -p='[{"op": "remove", "path": "/metadata/finalizers/0"}]'
```

#### Option 3: Fix Dependent Resources

Identify and fix the underlying issue causing the finalizer to not be removed:

1. Find dependent resources
2. Delete or fix them
3. Allow the controller to naturally remove the finalizer

### Prevention

1. **Understand resource scope**: Cluster-scoped resources (like GatewayClass) should NOT have a namespace field in manifests
2. **Use proper Kustomize configuration**: Don't apply namespace transformers to cluster-scoped resources
3. **Monitor Argo CD health**: Set up alerts for applications stuck in `Progressing` state
4. **Review finalizers**: Understand what each finalizer does before removing it

### Example: GatewayClass Stuck in Deletion

```yaml
# Problem: Resource stuck with this status
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  deletionTimestamp: "2026-02-14T20:11:44Z"  # Marked for deletion
  finalizers:
  - gateway-exists-finalizer.gateway.networking.k8s.io  # Blocking deletion
  name: envoy-gateway
```

**Why stuck**: Gateway resources still exist using this GatewayClass, so the finalizer won't be removed.

**Solution**:
```bash
# Remove finalizer to allow deletion
kubectl patch gatewayclass envoy-gateway --type=json \
  -p='[{"op": "remove", "path": "/metadata/finalizers"}]'

# Wait a few seconds for deletion
sleep 5

# Verify recreation by Argo CD
kubectl get gatewayclass envoy-gateway

# Check Argo CD health
kubectl get application -n argo-cd envoy-gateway \
  -o jsonpath='{.status.health.status}'
```

### Related Resources

- [Kubernetes Finalizers](https://kubernetes.io/docs/concepts/overview/working-with-objects/finalizers/)
- [Gateway API Finalizers](https://gateway-api.sigs.k8s.io/)
- [Argo CD Health Assessment](https://argo-cd.readthedocs.io/en/stable/operator-manual/health/)

## Common Argo CD Health Status Issues

### "Progressing" vs "Degraded" vs "Healthy"

- **Healthy**: All resources are healthy and in desired state
- **Progressing**: Resources are being updated or are in a transitional state
  - Normal during deployments
  - **Concerning if stuck for >30 minutes**
- **Degraded**: One or more resources are unhealthy

### Diagnostic Steps

1. **Check application details**:
   ```bash
   kubectl get application -n argo-cd <app-name> -o yaml
   ```

2. **Check specific resource health**:
   ```bash
   kubectl get application -n argo-cd <app-name> \
     -o jsonpath='{.status.resources[*]}' | jq
   ```

3. **Check for stuck deletions**:
   ```bash
   kubectl get application -n argo-cd <app-name> \
     -o jsonpath='{.status.resources[?(@.status=="OutOfSync")]}' | jq
   ```

4. **Force refresh**:
   ```bash
   argocd app get <app-name> --refresh
   # or via kubectl
   kubectl patch application -n argo-cd <app-name> \
     --type=merge -p='{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"normal"}}}'
   ```
