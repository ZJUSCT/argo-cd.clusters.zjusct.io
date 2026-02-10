# ZJUSCT Observability Stack on Kubernetes

This directory contains the Kubernetes deployment configuration for the ZJUSCT observability system, migrated from Docker Compose at `grafana.clusters.zjusct.io`.

## Architecture

The observability stack consists of:

- **Grafana** - Visualization and alerting dashboards
- **Prometheus** - Metrics storage with 180-day retention
- **ClickHouse** - Logs and traces storage
- **InfluxDB 2** - Time series data storage
- **OpenTelemetry Collector (Gateway)** - Main data collection gateway
  - Receives OTLP (HTTP/gRPC), Syslog, and NetFlow data
  - Exports to ClickHouse and Prometheus
- **OpenTelemetry Collector (SNMP)** - SNMP polling for infrastructure devices (PDUs, switches)
- **OpenTelemetry Collector (Check)** - Health checks (HTTP, TCP, TLS certificate monitoring)

## Directory Structure

```
observability/
├── kustomization.yaml           # Main kustomize configuration
├── values/                      # Helm chart values files
│   ├── grafana.yaml
│   ├── prometheus.yaml
│   ├── clickhouse.yaml
│   ├── influxdb.yaml
│   ├── otelcol-gateway.yaml
│   ├── otelcol-snmp.yaml
│   └── otelcol-check.yaml
├── resources/                   # Additional Kubernetes resources
│   ├── namespace.yaml
│   ├── grafana-datasources.yaml
│   └── secrets-template.yaml
└── README.md
```

## Prerequisites

1. **Sealed Secrets Controller** installed in the cluster
2. **Storage class** configured for persistent volumes
3. **Ingress controller** (nginx) for external access to Grafana
4. **Cert-manager** for TLS certificates

## Deployment Steps

### 1. Create Sealed Secrets

First, create secrets from the original Docker environment:

```bash
# Get credentials from the old system
cd /pool/nvme/ops/grafana.clusters.zjusct.io
source .env

# Create and seal OpenTelemetry secrets
kubectl create secret generic otelcol-secrets \
  --namespace=observability \
  --from-literal=bearer-token="$OTEL_BEARER_TOKEN" \
  --from-literal=snmp-auth-key="$SNMP_AUTH_KEY" \
  --from-literal=snmp-private-key="$SNMP_PRIVATE_KEY" \
  --dry-run=client -o yaml | \
  kubeseal --format yaml > argo-cd.clusters.zjusct.io/production/observability/resources/otelcol-sealedsecret.yaml

# Create and seal Grafana secrets
kubectl create secret generic grafana-secrets \
  --namespace=observability \
  --from-literal=admin-password="$GF_SECURITY_ADMIN_PASSWORD" \
  --from-literal=gf-tg-bot-token="$GF_TG_BOT_TOKEN" \
  --from-literal=gf-tg-chat-id="$GF_TG_CHAT_ID" \
  --dry-run=client -o yaml | \
  kubeseal --format yaml > argo-cd.clusters.zjusct.io/production/observability/resources/grafana-sealedsecret.yaml

# Create and seal InfluxDB secrets
kubectl create secret generic influxdb-secrets \
  --namespace=observability \
  --from-literal=admin-password="$INFLUXDB_PASSWORD" \
  --from-literal=admin-token="$INFLUXDB_TOKEN" \
  --dry-run=client -o yaml | \
  kubeseal --format yaml > argo-cd.clusters.zjusct.io/production/observability/resources/influxdb-sealedsecret.yaml
```

### 2. Update Kustomization

Uncomment the sealed secret resources in `kustomization.yaml`:

```yaml
resources:
  - resources/namespace.yaml
  - resources/grafana-datasources.yaml
  - resources/otelcol-sealedsecret.yaml
  - resources/grafana-sealedsecret.yaml
  - resources/influxdb-sealedsecret.yaml
```

### 3. Migrate Grafana Provisioning

The Grafana provisioning configurations (dashboards, alerting, etc.) from the Docker setup need to be migrated to Kubernetes ConfigMaps:

```bash
# Create ConfigMaps for Grafana dashboards
kubectl create configmap grafana-dashboards \
  --namespace=observability \
  --from-file=grafana.clusters.zjusct.io/config/grafana/provisioning/dashboards/
```

Update `values/grafana.yaml` to mount these ConfigMaps.

### 4. Deploy via ArgoCD

The ArgoCD ApplicationSet will automatically detect this directory and create an application.

Verify the application status:

```bash
argocd app list | grep observability
argocd app sync observability
```

## Migration Notes

### Data Migration

To migrate existing data from Docker volumes:

1. **Prometheus**: Export data using `promtool` and import to new instance
2. **ClickHouse**: Backup using `clickhouse-backup` and restore to Kubernetes
3. **InfluxDB**: Use `influx backup` and `influx restore`
4. **Grafana**: Dashboards are provisioned via ConfigMaps, user data can be exported/imported

### Configuration Changes

Key differences from Docker setup:

1. **Service names**: Services are now accessed via Kubernetes DNS (e.g., `prometheus-server.observability.svc.cluster.local`)
2. **Persistence**: Uses Kubernetes PersistentVolumeClaims instead of bind mounts
3. **Secrets**: Managed via SealedSecrets instead of `.env` files
4. **Networking**: Uses Ingress instead of direct port exposure

### Network Ports

The OpenTelemetry gateway service requires external access for:

- **OTLP HTTP** (4318): For agent data ingestion with authentication
- **Syslog UDP** (514): For infrastructure device logs
- **NetFlow UDP** (2055): For network flow data

Configure these as LoadBalancer service or NodePort as needed.

## Customization

### SNMP Configuration

The `otelcol-snmp.yaml` values file contains a placeholder. You need to:

1. Copy the full SNMP receiver configurations from `grafana.clusters.zjusct.io/config/otelcol/snmp.yaml`
2. Update the receivers section in `values/otelcol-snmp.yaml`
3. Ensure all PDU endpoints and OIDs are correct

### Check Configuration

Review and update the check targets in `values/otelcol-check.yaml`:

- TLS certificate checks
- TCP connectivity checks
- HTTP health checks

Add or remove targets based on current infrastructure.

### Storage Sizing

Review and adjust persistent volume sizes in values files:

- Grafana: 10Gi (default)
- Prometheus: 50Gi (180-day retention)
- ClickHouse: 100Gi
- InfluxDB: 50Gi (180-day retention)

## Monitoring

Access the Grafana dashboard:

```
https://grafana.clusters.zjusct.io
```

Default credentials:
- Username: `admin`
- Password: Set via sealed secret

## Troubleshooting

### Check pod status

```bash
kubectl get pods -n observability
```

### View logs

```bash
kubectl logs -n observability deployment/grafana
kubectl logs -n observability deployment/otelcol-gateway
```

### Verify data flow

1. Check OpenTelemetry Collector health: `http://otelcol-gateway:13133`
2. Check Prometheus targets: `http://prometheus-server:9090/targets`
3. Test ClickHouse: `kubectl exec -n observability deployment/clickhouse -- clickhouse-client --query "SHOW DATABASES"`

## References

- [Original Docker setup](../../../grafana.clusters.zjusct.io/)
- [OpenTelemetry Collector Helm Chart](https://github.com/open-telemetry/opentelemetry-helm-charts)
- [Grafana Helm Chart](https://github.com/grafana/helm-charts)
- [Prometheus Helm Chart](https://github.com/prometheus-community/helm-charts)
