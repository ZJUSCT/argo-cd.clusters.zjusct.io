#!/usr/bin/env bash
set -xeou pipefail

export PACKER_LOG=1
export PACKER_LOG_PATH="packer.log"

#    -debug -on-error=ask \
# -on-error=abort will leave the output files for debugging
packer build \
    -on-error=abort \
    .
if [ -f output/zjusct-full.qcow2 ]; then
    echo "Output info:"
    qemu-img info output/zjusct-full.qcow2
    sha256sum output/zjusct-full.qcow2
fi
