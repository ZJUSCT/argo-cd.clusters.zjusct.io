# OpenClaw Custom Image Build

This directory contains the configuration for building a custom OpenClaw image with pre-installed plugins using BuildKit.

## Overview

The custom image extends the base OpenClaw image and pre-installs the following plugins:
- `@sliverp/qqbot@latest` - QQ Bot integration plugin

## Files

- `Dockerfile` - Dockerfile for building the custom image
- `build.yaml` - Build configuration metadata
- `build.sh` - Shell script for building with BuildKit in Kubernetes
- `Jenkinsfile` - Jenkins Pipeline for automated builds
- `README.md` - This file

## Why Custom Image?

The standard OpenClaw image has a read-only filesystem for security. Installing plugins at runtime requires:
1. Writable `/home/node/.npm` directory for npm cache
2. Network access to npm registry during pod startup
3. Potential for inconsistency between pod restarts

By pre-installing plugins in a custom image:
- ✅ Maintains read-only filesystem security
- ✅ Faster pod startup (no plugin download)
- ✅ Consistent plugin versions across all pods
- ✅ GitOps-friendly approach

## Why BuildKit?

We use BuildKit instead of Kaniko because:
- Kaniko has been officially archived (as of 2024)
- BuildKit is the modern, actively maintained solution
- BuildKit rootless mode provides better security (runs as UID 1000)
- Better caching and multi-stage build support

## Building the Image

### Using Jenkins (Recommended)

The Jenkins Job Builder configuration at `jenkins/image-builds.yaml` creates the following jobs:

1. **Automated builds**: `image-build-dev-openclaw`
   - Triggers on changes to `dev/openclaw/build/*`
   - Rebuilds daily
   - Uses git commit SHA as tag

2. **Manual builds**: `image-build-manual`
   - Build on-demand with custom parameters
   - Useful for testing

### Manual Build (for testing)

```bash
# Build locally (requires Docker)
cd dev/openclaw/build
docker build -t harbor.clusters.zjusct.io/dev/openclaw:test .

# Push to registry
docker push harbor.clusters.zjusct.io/dev/openclaw:test
```

### Using the build script with BuildKit

```bash
cd dev/openclaw/build
./build.sh harbor.clusters.zjusct.io my-custom-tag jenkins
# Arguments: <registry> <tag> <namespace>
```

## Updating the Deployment

After building the custom image, update `dev/openclaw/values.yaml` to use it:

```yaml
app-template:
  controllers:
    main:
      containers:
        main:
          image:
            repository: harbor.clusters.zjusct.io/dev/openclaw
            tag: "latest"  # or specific commit SHA
```

Then commit and push. ArgoCD will automatically sync the changes.

## Adding More Plugins

To add more plugins:

1. Edit `build.yaml` and add to the `plugins` list
2. Edit `Dockerfile` and add RUN commands to install the plugins
3. Commit and push - Jenkins will automatically rebuild

Example:

```dockerfile
# Install multiple plugins
RUN node dist/index.js plugins install @sliverp/qqbot@latest && \
    node dist/index.js plugins install another-plugin@latest
```

## Troubleshooting

### Plugin installation fails

Check the plugin name and version:
```bash
# In the pod
npm search @sliverp/qqbot
```

### Image build fails in Jenkins

Check Jenkins build logs and BuildKit pod logs:
```bash
kubectl logs -n jenkins <buildkit-pod-name> -c buildctl
kubectl logs -n jenkins <buildkit-pod-name> -c buildkitd
```

### Plugin not working after deployment

Verify plugin is installed in the image:
```bash
# Exec into running pod
kubectl exec -it -n dev deploy/openclaw-main -- node dist/index.js plugins list
```

## References

- [OpenClaw Documentation](https://github.com/openclaw/openclaw)
- [BuildKit Documentation](https://github.com/moby/buildkit)
- [BuildKit Kubernetes Examples](https://github.com/moby/buildkit/blob/master/examples/kubernetes/README.md)
- [Jenkins Kubernetes Plugin](https://plugins.jenkins.io/kubernetes/)
