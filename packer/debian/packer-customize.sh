#!/usr/bin/env bash
set -xeou pipefail

export PACKER_LOG=1
export PACKER_LOG_PATH="packer.log"

packer build \
    -on-error=abort \
    -only="customize.qemu.ubuntu" .
if [ -f output-customize/customize.qcow2 ]; then
    echo "Output info:"
    qemu-img info output-customize/customize.qcow2
    sha256sum output-customize/customize.qcow2
fi
