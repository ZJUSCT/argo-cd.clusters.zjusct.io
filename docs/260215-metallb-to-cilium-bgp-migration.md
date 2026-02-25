# MetalLB to Cilium BGP Control Plane Migration

**Date:** 2026-02-15
**Status:** ✅ Successful

## Overview

Successfully migrated from MetalLB to Cilium's native BGP Control Plane, consolidating the cluster's networking stack into a single CNI solution. This eliminated operational complexity and reduced the number of components to maintain.

## Critical Issue: BGP CRDs Not Registered

### Problem

After enabling `bgpControlPlane.enabled: true` in Cilium configuration, BGP Control Plane appeared disabled:

```bash
$ kubectl exec -n default ds/cilium -- cilium bgp peers
BGP Control Plane is disabled
```

BGP CRDs were missing from the cluster:

```bash
$ kubectl get crd | grep ciliumbgp
# No results
```

### Root Cause

**The Cilium Operator only registers BGP-related CRDs when BGP Control Plane is enabled at operator startup time.**

Key findings:

1. Cilium ConfigMap showed BGP was enabled: `enable-bgp-control-plane: "true"`
2. Operator pods were running from before BGP was enabled in config
3. Operator startup logs showed only base CRDs were registered (identities, endpoints, nodes, network policies, etc.)
4. BGP CRDs were **not** registered at startup

### Solution

**Restart the Cilium Operator to trigger BGP CRD registration:**

```bash
kubectl rollout restart deployment/cilium-operator -n <namespace>
kubectl rollout status deployment/cilium-operator -n <namespace>
```

After restart, verify BGP CRDs are present:

```bash
$ kubectl get crd | grep ciliumbgp
ciliumbgpadvertisements.cilium.io
ciliumbgpclusterconfigs.cilium.io
ciliumbgpnodeconfigoverrides.cilium.io
ciliumbgpnodeconfigs.cilium.io
ciliumbgppeerconfigs.cilium.io
```

Operator logs will confirm:

```text
level=info msg="CRD is installed and up-to-date" name=ciliumbgpclusterconfigs.cilium.io
level=info msg="BGP control plane operator started"
```

## Configuration Application Sequence

```bash
# 1. Apply BGP configuration resources
kubectl apply -f production/default/resources/cilium-lb-ipam-pool.yaml
kubectl apply -f production/default/resources/cilium-bgp-cluster-config.yaml
kubectl apply -f production/default/resources/cilium-bgp-peer-config.yaml
kubectl apply -f production/default/resources/cilium-bgp-advertisement.yaml

# 2. Restart Cilium agents to pick up BGP configuration
kubectl rollout restart ds/cilium -n <namespace>
kubectl rollout status ds/cilium -n <namespace>

# 3. Verify BGP peering
kubectl exec -n default ds/cilium -- cilium bgp peers
```

Expected output after successful setup:

```text
Local AS   Peer AS   Peer Address       Session       Uptime   Family         Received   Advertised
<local>    <peer>    <router-ip>        established   50s      ipv4/unicast   N          M
```

## API Version Migration

Initial configuration used deprecated `v2alpha1` API versions:

```text
Warning: cilium.io/v2alpha1 CiliumBGPClusterConfig is deprecated; use cilium.io/v2
```

**Fix:** Update all BGP resources to use `cilium.io/v2`:

- `cilium-lb-ipam-pool.yaml`
- `cilium-bgp-cluster-config.yaml`
- `cilium-bgp-peer-config.yaml`
- `cilium-bgp-advertisement.yaml`

Change:

```yaml
apiVersion: cilium.io/v2alpha1  # OLD
```

To:

```yaml
apiVersion: cilium.io/v2  # NEW
```

## Verification Steps

### 1. BGP Session Status

```bash
kubectl exec -n default ds/cilium -- cilium bgp peers
```

Expected: `Session: established`

### 2. Advertised Routes

```bash
kubectl exec -n default ds/cilium -- cilium bgp routes advertised ipv4 unicast
```

Expected: See /32 routes for each LoadBalancer IP

### 3. Service IPs

```bash
kubectl get svc --all-namespaces -o wide | grep LoadBalancer
```

Verify all services have EXTERNAL-IP assigned

### 4. LB-IPAM Status

```bash
kubectl get ciliumloadbalancerippool -o yaml
```

Check status shows correct IP allocation

## Lessons Learned

### 1. Cilium Operator Restart Required for CRD Registration

**Key Insight:** When enabling new Cilium features (like BGP Control Plane) that require additional CRDs, the Cilium Operator must be restarted. Simply updating the ConfigMap is not sufficient.

**Why:** The operator registers CRDs during initialization based on enabled features at startup time. It does not dynamically register CRDs when configuration changes.

**Action:** Always restart the operator after enabling new Cilium features:

```bash
kubectl rollout restart deployment/cilium-operator -n <namespace>
```

### 2. Cilium Agent Restart Required for Config Changes

After applying BGP configuration changes, the Cilium DaemonSet must be restarted to pick up the new BGP settings:

```bash
kubectl rollout restart ds/cilium -n <namespace>
```

**Important:** During restart, expect brief network disruption (2-5 minutes) as pods restart node-by-node.

### 3. MetalLB and Cilium BGP Cannot Coexist

Both systems will attempt to peer with the same router using the same ASN, causing conflicts. The BGP session will flap or remain in `idle`/`active` state.

**Action:** Ensure MetalLB is completely removed before Cilium BGP becomes operational.

### 4. Service Annotation Migration

Services must use different annotations:

- **MetalLB:** `metallb.io/loadBalancerIPs`
- **Cilium:** `lbipam.cilium.io/ips`

For Gateway API resources, annotations must be placed in both metadata and infrastructure sections:

```yaml
metadata:
  annotations:
    lbipam.cilium.io/ips: "<ip-address>"
spec:
  infrastructure:
    annotations:
      lbipam.cilium.io/ips: "<ip-address>"
```

### 5. BGP Advertisement Selector Idiom

To advertise **all** LoadBalancer services, use this selector pattern:

```yaml
selector:
  matchExpressions:
  - key: somekey
    operator: NotIn
    values: ['never-used-value']
```

This is Cilium's idiom for "match everything" - the selector never matches the key, so `NotIn` effectively selects all services.

### 6. API Version Best Practices

Always use stable API versions when available:

- ✅ Use `cilium.io/v2` for production
- ❌ Avoid `cilium.io/v2alpha1` (deprecated)

### 7. Monitoring During Migration

Watch these indicators:

```bash
# BGP session state
watch -n 2 'kubectl exec -n default ds/cilium -- cilium bgp peers'

# Service IPs
watch -n 2 'kubectl get svc --all-namespaces -o wide | grep LoadBalancer'

# BGP routes
kubectl exec -n default ds/cilium -- cilium bgp routes advertised ipv4 unicast
```

## Troubleshooting Guide

### BGP Session in "idle" or "active" State

**Symptoms:**

```text
Session: idle or active (not established)
Received: 0
Advertised: 0
```

**Possible Causes:**

1. MetalLB still running (BGP conflict)
2. Router firewall blocking TCP port 179
3. Router peer configuration mismatch
4. Cilium agents haven't restarted since BGP config was applied

**Solutions:**

```bash
# Check for MetalLB pods
kubectl get pods -A | grep metallb

# Check Cilium agent uptime vs BGP config creation time
kubectl get pods -n default -l app.kubernetes.io/name=cilium
kubectl get ciliumbgpclusterconfig -o yaml | grep creationTimestamp

# Restart Cilium agents if needed
kubectl rollout restart ds/cilium -n <namespace>
```

### No Routes Advertised

**Symptoms:**

```text
VRouter   Peer   Prefix   NextHop   Age   Attrs
# Empty output
```

**Check:**

1. Verify LoadBalancer services exist and have EXTERNAL-IP assigned
2. Check BGP advertisement selector matches services
3. Verify LB-IPAM pool configuration

```bash
kubectl get svc --all-namespaces | grep LoadBalancer
kubectl get ciliumbgpadvertisement -o yaml
kubectl get ciliumloadbalancerippool -o yaml
```

### "BGP Control Plane is disabled" After Enabling

**Root Cause:** Cilium agents running with old configuration

**Solution:**

```bash
# Verify config is enabled
kubectl get cm -n <namespace> cilium-config -o yaml | grep bgp-control-plane

# Restart Cilium agents
kubectl rollout restart ds/cilium -n <namespace>
```

## Migration Checklist

- [ ] Enable BGP Control Plane in Cilium values file
- [ ] Restart Cilium Operator to register BGP CRDs
- [ ] Verify BGP CRDs are created
- [ ] Create LB-IPAM pool configuration
- [ ] Create BGP cluster configuration (ASN, peer config)
- [ ] Create BGP peer configuration (timers, graceful restart)
- [ ] Create BGP advertisement configuration
- [ ] Update service annotations from MetalLB to Cilium
- [ ] Restart Cilium agents
- [ ] Verify BGP session established
- [ ] Verify routes are advertised
- [ ] Test external connectivity to services
- [ ] Remove MetalLB
- [ ] Document configuration for future reference

## Performance Impact

- **Downtime:** ~2-5 minutes during Cilium agent restart
- **BGP Convergence:** ~10 seconds after agent restart
- **Service Recovery:** Immediate after BGP session established

## References

- [Cilium BGP Control Plane Documentation](https://docs.cilium.io/en/stable/network/bgp-control-plane/)
- [Cilium LB-IPAM Documentation](https://docs.cilium.io/en/stable/network/lb-ipam/)
- [Cilium Operator CRD Registration](https://docs.cilium.io/en/stable/operations/upgrade/)
