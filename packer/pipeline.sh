#!/usr/bin/env bash
set -xeou pipefail

cd "$(dirname "$0")"

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

COMMIT_HASH="${1:-$(git rev-parse --short HEAD)}"

rm -rf output output-base output-full

export PACKER_LOG=1
export PACKER_LOG_PATH="zjusct-base.log"

echo "Initializing Packer plugins..."
packer init .

echo "Validating configuration..."
packer validate .
cloud-init schema -c base/user-data
cloud-init schema -c full/user-data

echo "=========================================="
echo "Step 1/2: Building zjusct-base"
echo "=========================================="
packer build \
    -on-error=abort \
    -only='zjusct-base.qemu.ubuntu' \
    .

export PACKER_LOG_PATH="zjusct-full.log"

echo "=========================================="
echo "Step 2/2: Building zjusct-full"
echo "=========================================="
packer build \
    -on-error=abort \
    -only='zjusct-full.qemu.ubuntu' \
    .

echo "=========================================="
echo "Renaming with commit hash ${COMMIT_HASH}..."
echo "=========================================="
mv "output-base/zjusct-base.qcow2" "output-base/zjusct-base-${COMMIT_HASH}.qcow2"
mv "output-full/zjusct-full.qcow2" "output-full/zjusct-full-${COMMIT_HASH}.qcow2"

echo "=========================================="
echo "Generating SHA256SUMS..."
echo "=========================================="
(
    cd output-base && sha256sum "zjusct-base-${COMMIT_HASH}.qcow2"
    cd ../output-full && sha256sum "zjusct-full-${COMMIT_HASH}.qcow2"
) > SHA256SUMS
cat SHA256SUMS

echo "=========================================="
echo "Pipeline complete. Output:"
echo "=========================================="
qemu-img info "output-base/zjusct-base-${COMMIT_HASH}.qcow2"
qemu-img info "output-full/zjusct-full-${COMMIT_HASH}.qcow2"
