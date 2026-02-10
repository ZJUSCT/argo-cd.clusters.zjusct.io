# GZCTF Helm Chart

A Helm chart for deploying [GZCTF](https://github.com/GZTimeWalker/GZCTF) - A modern CTF (Capture The Flag) platform with Kubernetes integration.

## Introduction

GZCTF is a feature-rich CTF platform that supports dynamic container management through Kubernetes. This Helm chart deploys GZCTF along with its dependencies (PostgreSQL and Garnet cache) to your Kubernetes cluster.

## Prerequisites

- Kubernetes 1.19+
- Helm 3.0+
- PersistentVolume provisioner support in the underlying infrastructure
- Ingress controller (optional, for external access)

## Installation

### Quick Start

```bash
# Add your custom values
helm install my-gzctf ./gzctf -f values.yaml
```

### Using Custom Values

Create a `custom-values.yaml` file:

```yaml
gzctf:
  config:
    database:
      password: "your-strong-password"
    xorKey: "your-random-string"
    email:
      senderAddress: "noreply@yourdomain.com"
      password: "your-email-password"
      smtp:
        host: smtp.gmail.com
        port: 587
    containerProvider:
      publicEntry: "ctf.yourdomain.com"

  persistence:
    storageClassName: "your-storage-class"

postgresql:
  persistence:
    storageClassName: "your-storage-class"

ingress:
  enabled: true
  className: "nginx"
  hosts:
    - host: ctf.yourdomain.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: ctf-tls
      hosts:
        - ctf.yourdomain.com
```

Install with custom values:

```bash
helm install my-gzctf ./gzctf -f custom-values.yaml
```

## Configuration

### Essential Configuration

The following values **must be changed** before production deployment:

| Parameter | Description | Default |
|-----------|-------------|---------|
| `gzctf.config.database.password` | PostgreSQL password | `CHANGE_ME_DATABASE_PASSWORD` |
| `gzctf.config.xorKey` | Encryption key for sensitive data | `CHANGE_ME_RANDOM_STRING` |
| `gzctf.config.email.password` | SMTP password | `CHANGE_ME_EMAIL_PASSWORD` |
| `gzctf.config.containerProvider.publicEntry` | Public domain for the platform | `internal.example.com` |

### Storage Configuration

Configure persistent storage for data and database:

```yaml
gzctf:
  persistence:
    enabled: true
    storageClassName: "your-storage-class"  # e.g., "standard", "nfs-client"
    size: 4Gi

postgresql:
  persistence:
    enabled: true
    storageClassName: "your-storage-class"
    size: 1Gi
```

### Ingress Configuration

Enable and configure ingress for external access:

```yaml
ingress:
  enabled: true
  className: "nginx"  # or "traefik", "alb", etc.
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
  hosts:
    - host: ctf.yourdomain.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: ctf-tls
      hosts:
        - ctf.yourdomain.com
```

### HTTPRoute Configuration (Gateway API)

Gateway API is the next-generation routing API for Kubernetes. To use HTTPRoute:

**Prerequisites:**
- Install Gateway API CRDs: `kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.0.0/standard-install.yaml`
- Deploy a Gateway controller (e.g., Istio, Envoy Gateway, Cilium)
- Create a Gateway resource in your cluster

**Configuration:**

```yaml
httpRoute:
  enabled: true
  parentRefs:
    - name: my-gateway      # Name of your Gateway
      namespace: default     # Namespace of your Gateway
  hostnames:
    - ctf.yourdomain.com
```

**Advanced routing example:**

```yaml
httpRoute:
  enabled: true
  parentRefs:
    - name: my-gateway
      namespace: gateway-system
      sectionName: https    # Specific listener
  hostnames:
    - ctf.yourdomain.com
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      filters:
        - type: RequestHeaderModifier
          requestHeaderModifier:
            set:
              - name: X-Forwarded-Proto
                value: https
      backendRefs:
        - name: gzctf       # Will be auto-generated as <release-name>-gzctf
          port: 8080
```

## Accessing GZCTF

After installation, follow the instructions in the NOTES output:

```bash
# Port forward to access locally
export POD_NAME=$(kubectl get pods -l "app.kubernetes.io/name=gzctf,app.kubernetes.io/instance=my-gzctf" -o jsonpath="{.items[0].metadata.name}")
kubectl port-forward $POD_NAME 8080:8080

# Then visit http://127.0.0.1:8080
```

Or access via Ingress if enabled:
- https://ctf.yourdomain.com

## Uninstalling

```bash
helm uninstall my-gzctf
```

**Note**: This will not delete PersistentVolumeClaims. To delete them:

```bash
kubectl delete pvc -l app.kubernetes.io/instance=my-gzctf
```

## Components

This chart deploys the following components:

- **GZCTF Application**: The main CTF platform
- **PostgreSQL**: Database for storing CTF data
- **Garnet**: Redis-compatible cache for session management

Each component can be configured independently or disabled to use external services.

## Support

For issues and questions:
- GZCTF Project: https://github.com/GZTimeWalker/GZCTF
- Chart Issues: Please report in your repository
