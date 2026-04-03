#!/usr/bin/env bash
set -xeou pipefail

cd "$(dirname "$0")"

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

rm -rf output output-base output-full

export PACKER_LOG=1
export PACKER_LOG_PATH="packer.log"

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

echo "=========================================="
echo "Step 2/2: Building zjusct-full"
echo "=========================================="
packer build \
    -on-error=abort \
    -only='zjusct-full.qemu.ubuntu' \
    .

echo "=========================================="
echo "Collecting output..."
echo "=========================================="
mkdir -p output
mv output-base/zjusct-base.qcow2 output/
mv output-full/zjusct-full.qcow2 output/

echo "=========================================="
echo "Pipeline complete. Output:"
echo "=========================================="
for img in output/zjusct-base.qcow2 output/zjusct-full.qcow2; do
    if [ -f "$img" ]; then
        echo "--- $img ---"
        qemu-img info "$img"
        sha256sum "$img"
    fi
done
