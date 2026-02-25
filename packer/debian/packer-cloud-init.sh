#!/usr/bin/env bash
set -xeou pipefail

export PACKER_LOG=1
export PACKER_LOG_PATH="packer.log"

#    -debug -on-error=ask \
# -on-error=abort will leave the output files for debugging
packer build \
    -on-error=abort \
    -only="cloud-init.qemu.ubuntu" .
if [ -f output-cloud-init/cloud-init.qcow2 ]; then
    echo "Output info:"
    qemu-img info output-cloud-init/cloud-init.qcow2
    sha256sum output-cloud-init/cloud-init.qcow2
fi
