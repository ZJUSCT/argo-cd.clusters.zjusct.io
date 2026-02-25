# Custom OpenClaw image with pre-installed plugins
# Base image
ARG OPENCLAW_VERSION=latest
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
RUN node dist/index.js plugins install @sliverp/qqbot@latest

# Verify plugin installation
RUN node dist/index.js plugins list || true

# ============================================================
# ClawHub Skills Installation
# ============================================================
# Install skills from ClawHub (https://clawhub.com)
# Create workspace directory structure
RUN mkdir -p /home/node/.openclaw/workspace/skills

WORKDIR /home/node/.openclaw/workspace

# Install ClawHub skills
# Add skill slugs to the list below to install them declaratively
RUN set -e; \
    for skill in weather; do \
        if [ -n "$skill" ]; then \
            echo "[$(date -Iseconds)] Installing skill: $skill"; \
            npx -y clawhub install "$skill" --no-input || \
            echo "[$(date -Iseconds)] WARNING: Failed to install skill: $skill"; \
        fi; \
    done; \
    echo "[$(date -Iseconds)] Skills initialization complete"

# ============================================================
# Runtime Dependencies (Optional)
# ============================================================
# Uncomment sections below to install additional runtimes:
#
# Install uv (Python package manager) for Python skills:
# RUN mkdir -p /home/node/.openclaw/bin && \
#     curl -LsSf https://astral.sh/uv/install.sh | \
#     env UV_INSTALL_DIR=/home/node/.openclaw/bin sh
# ENV PATH="/home/node/.openclaw/bin:${PATH}"
#
# Install pnpm for interface dependencies (e.g., MS Teams):
# RUN mkdir -p /home/node/.openclaw/pnpm && \
#     curl -fsSL https://get.pnpm.io/install.sh | \
#     env PNPM_HOME=/home/node/.openclaw/pnpm SHELL=/bin/sh sh -
# ENV PATH="/home/node/.openclaw/pnpm:${PATH}"
# RUN cd /home/node/.openclaw && \
#     pnpm install <your-package> --store-dir /home/node/.openclaw/.pnpm-store

# Reset to default working directory
WORKDIR /app

# Keep the original entrypoint and command
# (No changes needed - will inherit from base image)
