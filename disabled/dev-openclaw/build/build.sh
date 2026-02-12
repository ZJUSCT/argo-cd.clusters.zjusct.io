#!/bin/bash
# Build script for OpenClaw custom image using BuildKit service
set -euo pipefail

REGISTRY="${1:-harbor.clusters.zjusct.io}"
IMAGE_TAG="${2:-latest}"
BUILD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== OpenClaw Custom Image Build with BuildKit ==="
echo "Registry: $REGISTRY"
echo "Image Tag: $IMAGE_TAG"
echo "Build Directory: $BUILD_DIR"

# Read build configuration
BASE_TAG=$(grep "baseTag:" ../build.yaml | awk '{print $2}' | tr -d '"')
TARGET_IMAGE="$REGISTRY/dev/openclaw"

echo "Base Tag: $BASE_TAG"
echo "Target Image: $TARGET_IMAGE:$IMAGE_TAG"

# Use BuildKit service in cluster
export BUILDKIT_HOST="tcp://buildkitd.buildkit.svc.cluster.local:1234"

cd "$BUILD_DIR"

buildctl build \
  --frontend dockerfile.v0 \
  --local context=. \
  --local dockerfile=. \
  --opt filename=Dockerfile \
  --opt build-arg:OPENCLAW_VERSION="$BASE_TAG" \
  --output type=image,name="$TARGET_IMAGE:$IMAGE_TAG",push=true \
  --output type=image,name="$TARGET_IMAGE:latest",push=true \
  --export-cache type=inline \
  --import-cache type=registry,ref="$TARGET_IMAGE:buildcache"

echo "=== Build completed successfully ==="
echo "Image: $TARGET_IMAGE:$IMAGE_TAG"
echo "Image: $TARGET_IMAGE:latest"
