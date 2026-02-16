#!/bin/bash
# Simplified Packer build script - runs everything in one container
set -e

cd /workspace

echo "Step 1: Initializing Packer plugins..."
packer init ubuntu-simple.pkr.hcl

echo ""
echo "Step 2: Validating configuration..."
packer validate ubuntu-simple.pkr.hcl

echo ""
echo "Step 3: Building image..."
packer build ubuntu-simple.pkr.hcl

echo ""
echo "Build complete!"
if [ -f output/ubuntu-simple.qcow2 ]; then
    echo "Output info:"
    qemu-img info output/ubuntu-simple.qcow2
fi
