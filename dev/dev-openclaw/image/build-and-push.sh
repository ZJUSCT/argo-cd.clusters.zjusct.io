#!/bin/bash
set -xeuo pipefail

# Configuration
REGISTRY="harbor.clusters.zjusct.io"
IMAGE_NAME="library/openclaw"
OPENCLAW_VERSION="${OPENCLAW_VERSION:-latest}"

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Generate ISO 8601 timestamp (format: 2026-02-13T103045Z)
TIMESTAMP=$(date -u +"%Y-%m-%dT%H%M%SZ")

# Define image tags
IMAGE_BASE="${REGISTRY}/${IMAGE_NAME}"
IMAGE_TAG_TIMESTAMP="${IMAGE_BASE}:${TIMESTAMP}"
IMAGE_TAG_LATEST="${IMAGE_BASE}:latest"

echo "=========================================="
echo "Building OpenClaw Docker Image"
echo "=========================================="
echo "Base version: ${OPENCLAW_VERSION}"
echo "Timestamp tag: ${TIMESTAMP}"
echo "Image: ${IMAGE_TAG_TIMESTAMP}"
echo "=========================================="

# Build the image
echo "Building Docker image..."
docker build \
    --progress=plain \
    --build-arg OPENCLAW_VERSION="${OPENCLAW_VERSION}" \
    -t "${IMAGE_TAG_TIMESTAMP}" \
    -t "${IMAGE_TAG_LATEST}" \
    "${SCRIPT_DIR}"

echo "✓ Build completed successfully"

# Push the images
echo "Pushing image with timestamp tag..."
docker push "${IMAGE_TAG_TIMESTAMP}"
echo "✓ Pushed ${IMAGE_TAG_TIMESTAMP}"

echo "Pushing image with latest tag..."
docker push "${IMAGE_TAG_LATEST}"
echo "✓ Pushed ${IMAGE_TAG_LATEST}"

echo "=========================================="
echo "Build and push completed successfully!"
echo "=========================================="
echo "Tags:"
echo "  - ${IMAGE_TAG_TIMESTAMP}"
echo "  - ${IMAGE_TAG_LATEST}"
echo "=========================================="
