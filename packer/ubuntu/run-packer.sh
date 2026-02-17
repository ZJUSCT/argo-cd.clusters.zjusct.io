#!/bin/bash
# Simplified Packer build script - runs everything in one container
set -e

rm -rf output

export PACKER_LOG=1n
export PACKER_LOG_PATH="packer.log"

echo "Step 1: Initializing Packer plugins..."
packer init ubuntu.pkr.hcl

echo ""
echo "Step 2: Validating configuration..."
packer validate ubuntu.pkr.hcl

echo ""
echo "Step 3: Building image..."
# packer build -on-error=ask -debug ubuntu.pkr.hcl
packer build ubuntu.pkr.hcl

echo ""
echo "Build complete!"
if [ -f output/ubuntu.qcow2 ]; then
    echo "Output info:"
    qemu-img info output/ubuntu.qcow2
fi
