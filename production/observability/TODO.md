# Post-Migration TODO Checklist

## Pre-Deployment

- [ ] Review and adjust resource limits in all values files based on cluster capacity
- [ ] Update storage class names if not using default storage class
- [ ] Verify Helm chart repositories are accessible from the cluster
- [ ] Ensure SealedSecrets controller is installed and working

## Secrets Setup

- [ ] Extract credentials from Docker `.env` file at `grafana.clusters.zjusct.io/.env`
- [ ] Create and seal OpenTelemetry Collector secrets:
  - `OTEL_BEARER_TOKEN`
  - `SNMP_AUTH_KEY`
  - `SNMP_PRIVATE_KEY`
- [ ] Create and seal Grafana secrets:
  - Admin password
  - Telegram bot token
  - Telegram chat ID
- [ ] Create and seal InfluxDB secrets:
  - Admin password
  - Admin token
- [ ] Uncomment sealed secret resources in `kustomization.yaml`

## Configuration Migration

### Grafana

- [ ] Migrate dashboards from `grafana.clusters.zjusct.io/config/grafana/provisioning/dashboards/`
  - Create ConfigMaps for dashboard JSON files
  - Update `values/grafana.yaml` to mount dashboard ConfigMaps
- [ ] Migrate alerting rules from `grafana.clusters.zjusct.io/config/grafana/provisioning/alerting/`
  - Create ConfigMaps for alert rules
  - Create ConfigMaps for contact points
- [ ] Verify Grafana configuration in `grafana.ini` section matches requirements
- [ ] Test OpenTelemetry tracing to `otelcol-gateway:4317`

### OpenTelemetry Collector - SNMP

- [ ] Copy full SNMP receiver configurations from `grafana.clusters.zjusct.io/config/otelcol/snmp.yaml`
- [ ] Update `values/otelcol-snmp.yaml` with:
  - PDU endpoints and credentials
  - SNMP OIDs and metrics definitions
  - Resource attributes
- [ ] Add all SNMP receivers to the service.pipelines.metrics.receivers list
- [ ] Verify SNMP endpoints are reachable from Kubernetes cluster network

### OpenTelemetry Collector - Check

- [ ] Review and update health check targets in `values/otelcol-check.yaml`:
  - TLS certificate expiration checks
  - TCP connectivity checks for cluster nodes
  - HTTP health checks for services
  - Internet connectivity checks
- [ ] Add any missing endpoints
- [ ] Remove any obsolete endpoints

### OpenTelemetry Collector - Gateway

- [ ] Configure LoadBalancer or NodePort for external access to:
  - OTLP HTTP (port 4318) - for authenticated agent ingestion
  - Syslog UDP (port 514) - for infrastructure device logs
  - NetFlow UDP (port 2055) - for network flow data
- [ ] Update firewall rules to allow traffic from:
  - OpenTelemetry agents on cluster nodes
  - Infrastructure devices (switches, routers, PDUs)
  - External monitoring agents
- [ ] Verify bearer token authentication is working

## Data Migration

- [ ] Plan maintenance window for data migration
- [ ] Backup Docker volume data:
  - [ ] Prometheus: `docker exec prometheus promtool tsdb snapshot /prometheus`
  - [ ] ClickHouse: Use `clickhouse-backup`
  - [ ] InfluxDB: `docker exec influxdb influx backup /backup`
  - [ ] Grafana: Export dashboards (if not using provisioning)
- [ ] Restore data to Kubernetes volumes:
  - [ ] Prometheus: Import snapshot
  - [ ] ClickHouse: Restore backup
  - [ ] InfluxDB: `influx restore`

## Network Configuration

- [ ] Update DNS records to point to new Kubernetes services
- [ ] Configure Ingress for Grafana:
  - [ ] Verify `grafana.clusters.zjusct.io` Ingress is created
  - [ ] Ensure TLS certificate is issued by cert-manager
  - [ ] Test HTTPS access
- [ ] Update OpenTelemetry agent configurations to point to new gateway:
  - [ ] Update agent endpoint from Docker host to Kubernetes service/LoadBalancer
  - [ ] Test agent connectivity and data flow

## Verification

- [ ] Check all pods are running: `kubectl get pods -n observability`
- [ ] Verify services are accessible:
  - [ ] Grafana UI: `https://grafana.clusters.zjusct.io`
  - [ ] Prometheus: `kubectl port-forward -n observability svc/prometheus-server 9090:9090`
  - [ ] ClickHouse: `kubectl exec -n observability deployment/clickhouse -- clickhouse-client --query "SHOW DATABASES"`
  - [ ] InfluxDB: `kubectl port-forward -n observability svc/influxdb 8086:8086`
- [ ] Verify data ingestion:
  - [ ] Check OpenTelemetry gateway health: `kubectl port-forward -n observability svc/otelcol-gateway 13133:13133` then visit `http://localhost:13133`
  - [ ] Verify metrics in Prometheus: Check `/targets` page
  - [ ] Verify logs in ClickHouse: Query logs table
  - [ ] Check Grafana datasource connectivity: Test all datasources
- [ ] Test dashboards:
  - [ ] Open each migrated dashboard
  - [ ] Verify data is displayed correctly
  - [ ] Check for any broken panels
- [ ] Test alerting:
  - [ ] Verify alert rules are loaded
  - [ ] Test notification channels (Telegram)
  - [ ] Create test alert to verify end-to-end flow

## Agent Deployment

- [ ] Deploy OpenTelemetry agents on cluster nodes
  - [ ] Use DaemonSet for node-level collection
  - [ ] Configure agent to forward to gateway
  - [ ] Enable host metrics, journald logs, Docker logs
- [ ] Update external agents (outside Kubernetes) to point to new gateway LoadBalancer/NodePort

## Monitoring

- [ ] Set up monitoring for the observability stack itself
  - [ ] Enable ServiceMonitors for Prometheus to scrape exporters
  - [ ] Create alerts for:
    - [ ] High memory/CPU usage
    - [ ] Pod restarts
    - [ ] Storage filling up
    - [ ] Data ingestion failures
- [ ] Set up backup jobs for persistent data
- [ ] Document runbooks for common issues

## Decommissioning Old System

- [ ] Run both systems in parallel for at least 1 week
- [ ] Compare data between old and new systems
- [ ] Migrate any remaining dependencies
- [ ] Stop Docker Compose services: `cd grafana.clusters.zjusct.io && docker compose down`
- [ ] Archive Docker configuration: `tar -czf grafana-docker-backup-$(date +%Y%m%d).tar.gz grafana.clusters.zjusct.io/`
- [ ] Update documentation to reference new Kubernetes deployment

## Documentation

- [ ] Update internal documentation with new URLs and access methods
- [ ] Create troubleshooting guide
- [ ] Document backup and restore procedures
- [ ] Create runbook for common operational tasks
- [ ] Update team onboarding documentation

## Optional Enhancements

- [ ] Set up automated dashboard backups
- [ ] Implement GitOps workflow for dashboard changes
- [ ] Add Grafana OnCall or Alertmanager for advanced alerting
- [ ] Consider deploying Grafana Loki for log aggregation
- [ ] Evaluate Grafana Tempo for distributed tracing
- [ ] Set up Grafana Mimir for long-term metrics storage
