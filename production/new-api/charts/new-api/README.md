# new-api Helm Chart

Helm Chart for deploying new-api on Kubernetes using StatefulSet.

## Quick Start

### Single Replica (Simple Deployment)

```bash
# 1. Customize values (copy example and modify)
cp values.example.yaml myvalues.yaml
# Edit myvalues.yaml with your database credentials

# 2. Deploy from OCI registry (auto-create namespace)
helm install new-api oci://ghcr.io/douglarek/newapi-helm/new-api -f myvalues.yaml -n new-api --create-namespace
```

### With Private Registry

```bash
# 1. Create namespace and image pull secret
kubectl create namespace new-api
kubectl create secret docker-registry registry-secret \
  --docker-server=<registry-url> \
  --docker-username=<username> \
  --docker-password=<password> \
  -n new-api

# 2. Deploy with image pull secret
helm install new-api oci://ghcr.io/douglarek/newapi-helm/new-api -f myvalues.yaml -n new-api --create-namespace
```

## Prerequisites

- Kubernetes cluster 1.19+
- Helm 3.0+
- External PostgreSQL database
- External Redis instance

## Repository Structure

```
new-api/
├── Chart.yaml            # Chart metadata
├── values.yaml           # Default configuration
├── values.example.yaml   # Example configuration for deployment
├── README.md             # This file
└── templates/
    ├── _helpers.tpl      # Template helpers
    ├── statefulset.yaml  # StatefulSet definition
    ├── service.yaml      # Service definition
    ├── serviceaccount.yaml # ServiceAccount
    ├── ingress.yaml      # Optional Ingress
    └── pdb.yaml          # Optional PodDisruptionBudget
```

## Installation

### 1. Install from OCI Registry

```bash
# Install latest version (auto-create namespace)
helm install new-api oci://ghcr.io/douglarek/newapi-helm/new-api -n <namespace> --create-namespace

# Install specific version
helm install new-api oci://ghcr.io/douglarek/newapi-helm/new-api --version 0.3.6 -n <namespace> --create-namespace

# Pull to local
helm pull oci://ghcr.io/douglarek/newapi-helm/new-api --version 0.3.6
```

### 2. Configure values.yaml

Create a custom `myvalues.yaml` or modify the default `values.yaml`:

```yaml
# Database configuration (PostgreSQL)
database:
  type: postgresql  # Options: postgresql, mysql, empty for SQLite
  host: "your-postgres-host"
  port: 5432
  name: "new-api"
  username: "your-username"
  password: "your-password"

# Database configuration (MySQL)
database:
  type: mysql
  host: "your-mysql-host"
  port: 3306
  name: "new-api"
  username: "your-username"
  password: "your-password"

# Database configuration (SQLite - no external database)
database:
  type: ""  # Empty uses SQLite
  host: ""

# Required: Set Redis connection
redis:
  host: "redis-service"
  port: 6379
  password: ""  # Set if Redis requires authentication
  db: 0         # Redis database index (0-15)

# Multi-node deployment: Change this!
sessionSecret: "your-random-secret-string-here"

# Storage configuration
dataVolume:
  enabled: true
  storageClass: "local-path"  # or "nfs-client" for ReadWriteMany
  size: 10Gi

logsVolume:
  enabled: true
  type: pvc  # Options: pvc, emptyDir, hostPath
  pvc:
    storageClass: "local-path"
    size: 5Gi
```

### 3. Deploy

```bash
# Install from OCI registry (auto-create namespace)
helm install new-api oci://ghcr.io/douglarek/newapi-helm/new-api -f myvalues.yaml -n <namespace> --create-namespace

# Upgrade
helm upgrade new-api oci://ghcr.io/douglarek/newapi-helm/new-api -f myvalues.yaml -n <namespace>

# Or install from local directory
helm install new-api ./new-api -f myvalues.yaml -n <namespace> --create-namespace
```

## Configuration

### Key Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `replicaCount` | Number of replicas | 1 |
| `image.registry` | Container registry (empty for Docker Hub) | `''` |
| `image.repository` | Image repository | `calciumion/new-api` |
| `image.tag` | Image tag | `v1.0.0-rc.8` |
| `imagePullSecrets` | Image pull secrets for private registry | `[]` |
| `sessionSecret` | Session secret for multi-node | `change-me-for-multi-node-deployment` |
| `service.type` | Kubernetes Service type | `ClusterIP` |
| `service.port` | Service port | 3000 |
| `database.type` | Database type | `postgresql` |
| `database.host` | Database host (empty uses SQLite) | `''` |
| `database.port` | Database port | `5432` |
| `database.name` | Database name | `new-api` |
| `redis.host` | Redis host (required) | `''` |
| `dataVolume.enabled` | Enable data persistence | `false` |
| `dataVolume.storageClass` | Storage class for data (when enabled) | `''`|
| `dataVolume.size` | Data volume size (when enabled) | `1Gi` |
| `logsVolume.enabled` | Enable logs persistence | `false` |
| `logsVolume.type` | Logs storage type (when enabled) | `pvc` |
| `logsVolume.pvc.size` | Logs volume size (when enabled) | `1Gi` |

### Storage Options

#### Data Volume

| Setting | Description |
|---------|-------------|
| `enabled: false` | Use emptyDir (ephemeral, default) |
| `enabled: true, storageClass: local-path` | Persistent, ReadWriteOnce |
| `enabled: true, storageClass: nfs-client` | Persistent, ReadWriteMany (may have SQLite performance issues) |

**Note**: The application stores data using SQLite by default. SQLite may have performance issues when used with NFS storage. For production deployments with multiple replicas, consider using an external PostgreSQL database instead.

#### Logs Volume

| Setting | Description |
|---------|-------------|
| `enabled: false` | Use emptyDir (ephemeral, default) |
| `enabled: true, type: pvc` | Persistent volume claim |
| `enabled: true, type: emptyDir` | Ephemeral storage (lost on pod restart) |
| `enabled: true, type: hostPath` | Host filesystem path |

### Service Types

- `ClusterIP` - Cluster internal access only (default)
- `NodePort` - External access via node IP:nodePort
- `LoadBalancer` - External access via load balancer

## Multi-Node Deployment

When deploying multiple replicas (`replicaCount > 1`):

1. **Set `sessionSecret`**: Generate a random string
   ```bash
   openssl rand -hex 32
   ```

2. **Use ReadWriteMany storage**: For shared data access
   ```yaml
   dataVolume:
     storageClass: "nfs-client"
     accessMode: ReadWriteMany
   ```

3. **Consider external Redis**: Ensure Redis can handle multiple connections

## Health Checks

The chart configures three types of probes:

- **Liveness Probe**: Checks if the application is alive
- **Readiness Probe**: Checks if the application is ready to serve traffic
- **Startup Probe**: (Optional) For slow-starting containers

All probes use the `/api/status` endpoint.

## Uninstall

```bash
helm uninstall new-api -n <namespace>
```

## Troubleshooting

### Check Pod Status

```bash
kubectl get pods -n <namespace> -l app.kubernetes.io/name=new-api
kubectl describe pod -n <namespace> <pod-name>
kubectl logs -n <namespace> <pod-name>
```

### Common Issues

1. **ImagePullBackOff**: If using private registry, ensure image pull secret exists
   ```bash
   kubectl create secret docker-registry <secret-name> \
     --docker-server=<registry-url> \
     --docker-username=<username> \
     --docker-password=<password> \
     -n <namespace>
   ```

2. **Connection refused to database**: Verify PostgreSQL and Redis connectivity
   ```bash
   kubectl run -it --rm --restart=Never --image=postgres:15 test-pg \
     -- bash -c "pg_isready -h postgresql-ha-pgpool -p 5432" -n <namespace>
   ```

3. **PVC pending**: Check storage class availability
   ```bash
   kubectl get sc
   kubectl get pvc -n <namespace>
   ```

## Notes

- This chart uses **StatefulSet** for stable network identities and persistent storage
- Each pod gets its own PVC for the data volume (when using ReadWriteOnce)
- External PostgreSQL and Redis are required (not bundled in this chart)
- Change default passwords before production deployment
