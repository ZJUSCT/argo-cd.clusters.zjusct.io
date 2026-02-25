# Investigation Report: Intermittent “Connection Refused” in Tekton Proxy Webhook

## Problem Description (2026-02-19)

When scheduling the Pod for the `s3upload` Task in Tekton PipelineRun `packer-ubuntu-run-q2jhf-r-p5zt8`, the following error occurred:

```
failed to create task run pod "packer-ubuntu-run-q2jhf-r-p5zt8-upload-cloud-init":
Internal error occurred: failed calling webhook "proxy.operator.tekton.dev":
failed to call webhook:
Post "https://tekton-operator-proxy-webhook.tekton.svc:443/defaulting?timeout=10s":
dial tcp 172.27.71.5:443: connect: connection refused
```

The error message ends with a misleading hint —
“Maybe missing or invalid Task tekton/s3upload” — but verification confirmed that the Task does exist. The real cause was that the Webhook service intermittently refused connections.

---

## Root Cause

### Service Selector Label Collision

The `tekton-operator-proxy-webhook` Service uses the selector `name=tekton-operator`, which matches **two Pods** simultaneously:

| Pod                                             | Labels                                                   | Port 8443 Status             |
| ----------------------------------------------- | -------------------------------------------------------- | ---------------------------- |
| `tekton-operator-proxy-webhook-9c78d784f-kn2dw` | `name=tekton-operator, pod-template-hash=9c78d784f, ...` | ✅ Listening                  |
| `tekton-operator-f86dd5f64-xs7gj`               | `name=tekton-operator, pod-template-hash=f86dd5f64`      | ❌ Not listening (Port: none) |

The Service load-balances traffic across both Pods. Approximately 50% of Webhook requests were routed to the main `tekton-operator` controller Pod, which does not listen on port 8443, resulting in `connection refused`.

### Trigger Condition

Each time Tekton schedules a new TaskRun Pod, the kube-apiserver sends an Admission request to the `proxy.operator.tekton.dev` Webhook (configured via `MutatingWebhookConfiguration` with `failurePolicy: Fail`).
With ~50% probability, the request fails, causing TaskRun scheduling to fail immediately.

---

## Investigation Process

### 1. Environment Information

```
Tekton Operator version: v0.78.1
Webhook Pod: tekton-operator-proxy-webhook-9c78d784f-kn2dw (storage node, IP: 172.26.0.66)
Operator Pod: tekton-operator-f86dd5f64-xs7gj (m600 node, IP: 172.26.1.157)
Service ClusterIP: 172.27.71.5:443 -> targetPort 8443
```

### 2. Service Endpoint Analysis

The `tekton-operator-proxy-webhook` Service Endpoint was found to include two IPs:

```yaml
subsets:
- addresses:
  - ip: 172.26.0.66   # Correct: proxy-webhook pod
  - ip: 172.26.1.157  # Incorrect: tekton-operator pod
  ports:
  - port: 8443
```

Both Pods carry the `name=tekton-operator` label, and the Service selector cannot distinguish between them.

### 3. Direct Connectivity Tests

```bash
# Webhook Pod (172.26.0.66:8443) -> HTTP 415 (expected)
curl -k https://172.26.0.66:8443/healthz -> 415

# Operator Pod (172.26.1.157:8443) -> connection refused
curl -k https://172.26.1.157:8443/healthz -> 000 (FAILED)
```

### 4. Service-Level Stress Test (Before Fix)

```
Results of 10 requests:
req-1: 415 PASS  req-2: 000 FAIL  req-3: 000 FAIL
req-4: 000 FAIL  req-5: 000 FAIL  req-6: 415 PASS
req-7: 415 PASS  req-8: 000 FAIL  req-9: 415 PASS
req-10: 000 FAIL

Passed: 4/10, Failed: 6/10 (~50% failure rate)
```

### 5. Service Definition in TektonInstallerSet

Extracting the Service definition from TektonInstallerSet `pipeline-main-deployment-9945q` confirmed the root cause:

```json
{
  "kind": "Service",
  "metadata": {"name": "tekton-operator-proxy-webhook"},
  "spec": {
    "selector": {
      "name": "tekton-operator"
    }
  }
}
```

This selector does not use any label that uniquely identifies the proxy-webhook Pod. This is an upstream configuration defect in Tekton Operator v0.78.1.

---

## Applied Fix (Temporary)

### Action

An additional selector, `pod-template-hash`, was added to restrict the Service to the Webhook Pod only:

```bash
kubectl patch service tekton-operator-proxy-webhook -n tekton \
  --type=merge \
  -p '{"spec":{"selector":{"name":"tekton-operator","pod-template-hash":"9c78d784f"}}}'
```

After the fix, the Endpoint contains only the Webhook Pod:

```
172.26.0.66:8443  (tekton-operator-proxy-webhook pod only)
```

### Post-Fix Stress Test

```
20 requests: 20/20 passed (0 failures)
50 requests (via FQDN): 50/50 passed (0 failures)
```

### Persistence Analysis

The TektonInstallerSet reconciler uses the `operator.tekton.dev/last-applied-hash` annotation to determine whether a resource needs updating:

* If the hash in the annotation matches the expected hash in the InstallerSet spec, the resource is skipped (not force-overwritten)
* Our patch modified only `spec.selector`, not the hash annotation
* Since the reconciler sees matching hashes, it considers the resource already in the desired state and **does not roll back our change**

After 2 minutes of observation, periodic reconciliation by the Tekton Operator (every few minutes) did not revert the fix.

---

## Risks and Limitations

### Fragility of the Current Fix

Using `pod-template-hash: 9c78d784f` as an additional selector carries the following risks:

| Trigger Scenario                                   | Impact                                                                                                              |
| -------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| Tekton Operator upgrade                            | TektonPipeline recreates the TektonInstallerSet; Service selector resets to `name=tekton-operator`, issue reappears |
| TektonConfig / TektonPipeline configuration change | Same as above                                                                                                       |
| Webhook Deployment rolling update                  | `pod-template-hash` changes; new Pod no longer matches the Service selector → **all Webhook requests fail**         |

> ⚠️ Particularly dangerous: if the Webhook Deployment rolls without updating the Service selector, the Service will have no valid Endpoints, resulting in 100% Webhook failure.

---

## Recommended Permanent Fixes

### Option A: Upstream Bug Report (Recommended)

Submit a bug report to the Tekton Operator project:

* Issue: `tekton-operator-proxy-webhook` Service selector `name=tekton-operator` collides with Pod labels of the `tekton-operator` Deployment
* Suggested fix: add a unique label to the proxy-webhook Pod template (e.g., `app.kubernetes.io/component: proxy-webhook`) and update the Service selector accordingly

### Option B: Inject Labels via TektonPipeline Options (Feasibility Pending)

`TektonPipeline.spec.options.deployments` supports injecting additional labels into Deployment Pod templates. In GitOps configuration:

```yaml
# TektonConfig in production/tekton/resources/config.yaml
spec:
  pipeline:
    options:
      deployments:
        tekton-operator-proxy-webhook:
          spec:
            template:
              metadata:
                labels:
                  app.kubernetes.io/component: proxy-webhook
```

However, `options.services` is **not supported** in v0.78.1 (verified via `--dry-run=server` with error: `admission webhook denied: unknown field "services"`).
Thus, even if the Deployment label is injected, the Service selector would still require manual patching and remains vulnerable to rollback.

### Option C: Reapply Patch After Each Upgrade

After every Tekton Operator upgrade, perform:

```bash
# 1. Obtain the new pod-template-hash of the Webhook Pod
HASH=$(kubectl get pod -n tekton -l name=tekton-operator \
  -o jsonpath='{.items[?(@.metadata.labels.pod-template-hash!="")].metadata.labels.pod-template-hash}' \
  | tr ' ' '\n' | sort -u | grep -v $(kubectl get deploy tekton-operator -n tekton -o jsonpath='{.spec.selector.matchLabels.name}' 2>/dev/null || echo "xxx"))

# 2. Preferably fetch directly from the webhook deployment
HASH=$(kubectl get deploy tekton-operator-proxy-webhook -n tekton \
  -o jsonpath='{.spec.template.metadata.labels.pod-template-hash}')

# 3. Update the Service selector
kubectl patch service tekton-operator-proxy-webhook -n tekton \
  --type=merge \
  -p "{\"spec\":{\"selector\":{\"name\":\"tekton-operator\",\"pod-template-hash\":\"$HASH\"}}}"

# 4. Verify
kubectl get endpoints tekton-operator-proxy-webhook -n tekton
```

---

## Appendix: Related Notes

### MutatingWebhookConfiguration

```yaml
name: proxy.operator.tekton.dev
failurePolicy: Fail    # Critical: webhook failure directly rejects the request
namespaceSelector:
  matchExpressions:
  - key: operator.tekton.dev/disable-proxy
    operator: DoesNotExist
  - key: control-plane
    operator: DoesNotExist
```

`failurePolicy: Fail` is the direct reason TaskRun scheduling fails instead of degrading gracefully.

### Misleading TaskRun Error Message

```
Maybe missing or invalid Task tekton/s3upload
```

This message is appended by the Tekton Pipeline controller whenever Pod creation fails and applies to many failure scenarios (including Webhook failures). It does **not** indicate that the Task is actually missing. The `s3upload` Task was confirmed to exist in the `tekton` namespace.

### TektonInstallerSet Reconciliation Behavior

* The reconciler periodically (every few minutes) reconciles all InstallerSets
* It relies on the `operator.tekton.dev/last-applied-hash` annotation to avoid unnecessary overwrites
* Since the Service hash annotation was unchanged, the reconciler did not revert the fix
* However, when TektonPipeline is rebuilt due to configuration changes or version upgrades, the old hash becomes invalid and the Service is restored to its original (faulty) state

---

## Summary

| Item                  | Description                                                                                   |
| --------------------- | --------------------------------------------------------------------------------------------- |
| Root cause            | Service selector label collision in `tekton-operator-proxy-webhook` (Tekton Operator v0.78.1) |
| Impact                | ~50% Webhook request failure → TaskRun scheduling failures                                    |
| Fixed                 | Yes (temporary), by adding `pod-template-hash` to the Service selector                        |
| Fix durability        | Lasts until the next Tekton Operator upgrade or TektonConfig change                           |
| Recommended follow-up | Report upstream bug; reapply Service patch after each Tekton upgrade                          |
