# Harbor Registry

This directory contains the configuration for the Harbor registry deployed in the `default` namespace.

## Registry Health Check Mechanism

Harbor automatically performs health checks on all configured upstream registries (e.g., Docker Hub, ghcr.io, quay.io, etc.) to ensure they are accessible.

### Key Details

- **Default Interval**: 5 minutes (hardcoded in Harbor's source code)
- **What it does**:
    - Periodically checks the health status of all upstream registries
    - Marks registries as "healthy" or "unhealthy" based on connectivity
    - If a registry is marked as "unhealthy", Harbor will not attempt to proxy pulls through it
- **Recovery**:
    - Once a registry becomes available again, the next health check will mark it as "healthy"
    - Proxy pulls will resume automatically

### Can the Health Check Frequency Be Changed?

Currently, the health check interval is **not configurable** via environment variables or Helm chart values. It is hardcoded as `5 * time.Minute` in Harbor's source code (`src/controller/registry/controller.go`).

To change the interval, you would need to:

1. Modify the `regularHealthCheckInterval` variable in Harbor's source code
2. Rebuild the Harbor container image
3. Deploy the custom image

### Recommendation

We do **not** recommend changing the health check frequency, as it would require maintaining a custom build of Harbor. The default 5-minute interval is reasonable for most production use cases, balancing responsiveness with resource usage.

## Troubleshooting

If you encounter issues with image pulls through Harbor:

1. Check the harbor-core logs for health check errors:

   ```bash
   kubectl logs -n default deploy/harbor-core | grep -i health
   ```

2. Verify registry status in the Harbor UI or database
3. Wait up to 5 minutes for the next health check to run
