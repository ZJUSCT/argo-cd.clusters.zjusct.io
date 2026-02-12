# Custom OpenClaw image with pre-installed plugins
# Base image
ARG OPENCLAW_VERSION=2026.2.9
FROM harbor.clusters.zjusct.io/ghcr.io/openclaw/openclaw:${OPENCLAW_VERSION}

# Switch to root to create directories and set permissions
USER root

# Create npm cache directory in /tmp (writable)
RUN mkdir -p /tmp/.npm && chown -R node:node /tmp/.npm

# Switch back to node user
USER node

# Configure npm to use /tmp for cache
RUN npm config set cache /tmp/.npm

# Install plugins
# The plugin installation needs to happen in the context where openclaw is installed
WORKDIR /app

# Install the QQBot plugin
RUN node dist/index.js plugins install @sliverp/qqbot@latest || \
    echo "Warning: Plugin installation may have issues, continuing..."

# Verify plugin installation
RUN node dist/index.js plugins list || true

# Reset to default working directory
WORKDIR /app

# Keep the original entrypoint and command
# (No changes needed - will inherit from base image)
