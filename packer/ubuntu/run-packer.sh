#!/usr/bin/env bash
set -xeou pipefail

export PACKER_LOG=1
export PACKER_LOG_PATH="packer.log"

echo "Step 1: Initializing Packer plugins..."
packer init .

echo "Step 2: Validating configuration..."
packer validate .
cloud-init schema -c user-data

echo "Step 3: Building image..."
#    -debug -on-error=ask \
# -on-error=abort will leave the output files for debugging
packer build \
    -on-error=abort \
    -only="cloud-init.qemu.ubuntu" .
if [ -f output-cloud-init/cloud-init.qcow2 ]; then
    echo "Output info:"
    qemu-img info output-cloud-init/cloud-init.qcow2
fi
#    -debug -on-error=ask \
packer build \
    -on-error=abort \
    -only="customize.qemu.ubuntu" .
if [ -f output-customize/customize.qcow2 ]; then
    echo "Output info:"
    qemu-img info output-customize/customize.qcow2
fi
