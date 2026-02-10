# Quick Start Guide

## One-Time Setup

### 1. Create Sealed Secrets

```bash
# Navigate to old Docker setup
cd /pool/nvme/ops/grafana.clusters.zjusct.io

# Load environment variables
source .env

# Create OpenTelemetry secrets
kubectl create secret generic otelcol-secrets \
  --namespace=observability \
  --from-literal=bearer-token="$OTEL_BEARER_TOKEN" \
  --from-literal=snmp-auth-key="$SNMP_AUTH_KEY" \
  --from-literal=snmp-private-key="$SNMP_PRIVATE_KEY" \
  --dry-run=client -o yaml | \
  kubeseal --format yaml > ../argo-cd.clusters.zjusct.io/production/observability/resources/otelcol-sealedsecret.yaml

# Create Grafana secrets
kubectl create secret generic grafana-secrets \
  --namespace=observability \
  --from-literal=admin-user="admin" \
  --from-literal=admin-password="$GF_SECURITY_ADMIN_PASSWORD" \
  --from-literal=GF_SECURITY_ADMIN_PASSWORD="$GF_SECURITY_ADMIN_PASSWORD" \
  --from-literal=GF_TG_BOT_TOKEN="$GF_TG_BOT_TOKEN" \
  --from-literal=GF_TG_CHAT_ID="$GF_TG_CHAT_ID" \
  --dry-run=client -o yaml | \
  kubeseal --format yaml > ../argo-cd.clusters.zjusct.io/production/observability/resources/grafana-sealedsecret.yaml

# Create InfluxDB secrets
kubectl create secret generic influxdb-secrets \
  --namespace=observability \
  --from-literal=admin-password="$INFLUXDB_PASSWORD" \
  --from-literal=admin-token="$INFLUXDB_TOKEN" \
  --dry-run=client -o yaml | \
  kubeseal --format yaml > ../argo-cd.clusters.zjusct.io/production/observability/resources/influxdb-sealedsecret.yaml
```

### 2. Update Kustomization

Edit `kustomization.yaml` and uncomment the sealed secret resources:

```yaml
resources:
  - resources/namespace.yaml
  - resources/grafana-datasources.yaml
  - resources/clickhouse-statefulset.yaml
  - resources/otelcol-sealedsecret.yaml      # Uncomment this
  - resources/grafana-sealedsecret.yaml      # Uncomment this
  - resources/influxdb-sealedsecret.yaml     # Uncomment this
```

### 3. Commit and Push

```bash
cd /pool/nvme/ops/argo-cd.clusters.zjusct.io
git add production/observability/
git commit -m "Add observability stack for Kubernetes"
git push
```

### 4. Sync with ArgoCD

ArgoCD will automatically detect the new application. Sync it:

```bash
# Wait for ArgoCD to discover the application
argocd app list | grep observability

# Sync the application
argocd app sync observability

# Watch the sync progress
argocd app get observability --watch
```

## Daily Operations

### Check Application Status

```bash
# Via ArgoCD
argocd app get observability

# Via kubectl
kubectl get pods -n observability
kubectl get pvc -n observability
kubectl get svc -n observability
```

### View Logs

```bash
# Grafana logs
kubectl logs -n observability deployment/grafana -f

# OpenTelemetry gateway logs
kubectl logs -n observability deployment/otelcol-gateway -f

# Prometheus logs
kubectl logs -n observability deployment/prometheus-server -f

# ClickHouse logs
kubectl logs -n observability statefulset/clickhouse -f
```

### Access Services

```bash
# Grafana (via Ingress)
https://grafana.clusters.zjusct.io

# Prometheus (port-forward)
kubectl port-forward -n observability svc/prometheus-server 9090:9090
# Then open http://localhost:9090

# ClickHouse (port-forward)
kubectl port-forward -n observability svc/clickhouse 8123:8123
# Then open http://localhost:8123/play

# InfluxDB (port-forward)
kubectl port-forward -n observability svc/influxdb 8086:8086
# Then open http://localhost:8086

# OpenTelemetry Collector health check
kubectl port-forward -n observability svc/otelcol-gateway 13133:13133
# Then open http://localhost:13133
```

### Execute Commands in Pods

```bash
# ClickHouse client
kubectl exec -n observability statefulset/clickhouse -it -- clickhouse-client

# Example queries
kubectl exec -n observability statefulset/clickhouse -- clickhouse-client --query "SHOW DATABASES"
kubectl exec -n observability statefulset/clickhouse -- clickhouse-client --query "SHOW TABLES FROM otel"

# InfluxDB CLI
kubectl exec -n observability deployment/influxdb -it -- influx
```

## Troubleshooting

### Pods Not Starting

```bash
# Describe pod to see events
kubectl describe pod -n observability <pod-name>

# Check events in namespace
kubectl get events -n observability --sort-by='.lastTimestamp'
```

### Storage Issues

```bash
# Check PVC status
kubectl get pvc -n observability

# Check storage usage
kubectl exec -n observability statefulset/clickhouse -- df -h /var/lib/clickhouse
kubectl exec -n observability deployment/prometheus-server -- df -h /prometheus
```

### Secrets Not Found

```bash
# Check if secrets exist
kubectl get secrets -n observability

# If missing, recreate sealed secrets following step 1 above
```

### Data Not Flowing

```bash
# Check OpenTelemetry gateway health
kubectl port-forward -n observability svc/otelcol-gateway 13133:13133
curl http://localhost:13133

# Check Prometheus targets
kubectl port-forward -n observability svc/prometheus-server 9090:9090
# Open http://localhost:9090/targets

# Check if services can resolve each other
kubectl exec -n observability deployment/grafana -- nslookup prometheus-server
kubectl exec -n observability deployment/grafana -- nslookup clickhouse
```

### Restart Services

```bash
# Restart individual deployment
kubectl rollout restart -n observability deployment/grafana
kubectl rollout restart -n observability deployment/otelcol-gateway

# Restart statefulset (be careful with data)
kubectl rollout restart -n observability statefulset/clickhouse
```

## Updating Configuration

### Update Helm Values

1. Edit the values file (e.g., `values/grafana.yaml`)
2. Commit and push changes
3. ArgoCD will automatically sync (if auto-sync is enabled) or manually sync:

```bash
argocd app sync observability
```

### Add New Dashboard

1. Export dashboard JSON from Grafana UI
2. Create ConfigMap:

```bash
kubectl create configmap grafana-dashboard-<name> \
  --namespace=observability \
  --from-file=dashboard.json \
  --dry-run=client -o yaml > resources/dashboard-<name>.yaml
```

3. Add label to ConfigMap:

```yaml
metadata:
  labels:
    grafana_dashboard: "1"
```

4. Add to `kustomization.yaml` resources
5. Commit, push, and sync

## Backup and Restore

### Backup Prometheus Data

```bash
# Create snapshot
kubectl exec -n observability deployment/prometheus-server -- \
  promtool tsdb snapshot /prometheus

# Copy snapshot out
kubectl cp observability/prometheus-server-<pod-id>:/prometheus/snapshots/<snapshot-name> \
  ./prometheus-backup/
```

### Backup ClickHouse Data

```bash
# Install clickhouse-backup if not already present
# Then create backup
kubectl exec -n observability statefulset/clickhouse -- \
  clickhouse-backup create
```

### Backup InfluxDB Data

```bash
# Create backup
kubectl exec -n observability deployment/influxdb -- \
  influx backup /backup

# Copy backup out
kubectl cp observability/influxdb-<pod-id>:/backup \
  ./influxdb-backup/
```

## Monitoring the Observability Stack

### Check Resource Usage

```bash
# CPU and memory
kubectl top pods -n observability

# Storage
kubectl exec -n observability statefulset/clickhouse -- df -h
```

### Check Data Ingestion Rate

```bash
# In Prometheus UI, query:
# rate(prometheus_tsdb_head_samples_appended_total[5m])

# In ClickHouse:
kubectl exec -n observability statefulset/clickhouse -- clickhouse-client --query \
  "SELECT count(*) FROM system.query_log WHERE event_time > now() - INTERVAL 1 HOUR"
```

## Links

- [Full README](README.md)
- [TODO Checklist](TODO.md)
- [ArgoCD Dashboard](https://argo-cd.clusters.zjusct.io)
- [Grafana Dashboard](https://grafana.clusters.zjusct.io)
