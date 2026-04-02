#!/usr/bin/env bash
set -xeou pipefail

# need sudo to use KVM
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

rm -rf output

export PACKER_LOG=1
export PACKER_LOG_PATH="packer.log"

echo "Initializing Packer plugins..."
packer init .

echo "Validating configuration..."
packer validate .
cloud-init schema -c user-data

packer build \
    -on-error=abort \
    .
#    -debug -on-error=ask \
# -on-error=abort will leave the output files for debugging

if [ -f output/zjusct-full.qcow2 ]; then
    echo "Output info:"
    qemu-img info output/zjusct-full.qcow2
    sha256sum output/zjusct-full.qcow2
fi
