#!/bin/bash
# Simplified Packer build - runs everything in one container
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="harbor.clusters.zjusct.io/library/packer:latest"

echo "Building Ubuntu image with Packer..."
echo ""

# Run everything in a single container
docker run --rm --privileged \
    -v "${SCRIPT_DIR}:/workspace" \
    -w /workspace \
    ${IMAGE} bash /workspace/run.sh

echo ""
echo "Build complete! Output: ${SCRIPT_DIR}/output/ubuntu-simple.qcow2"
