#!/usr/bin/env bash
set -xeou pipefail

# need sudo to use KVM
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

export PACKER_LOG=1
export PACKER_LOG_PATH="packer.log"

rm -rf output

packer build \
    -on-error=abort \
    .
#    -debug -on-error=ask \
# -on-error=abort will leave the output files for debugging

if [ -f output/zjusct-base.qcow2 ]; then
    echo "Output info:"
    qemu-img info output/zjusct-base.qcow2
    sha256sum output/zjusct-base.qcow2
fi
