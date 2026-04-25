#!/usr/bin/env bash
# Script to run a QEMU virtual machine with the given image
# Can use SSH and console to interact with the VM
set -xeou pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <source_image> [arch]"
    echo "Example: $0 /path/to/image.qcow2 x86_64"
    exit 1
fi

SOURCE_IMAGE=$1
ARCH=${2:-x86_64}
TARGET_IMAGE="/tmp/debug.qcow2"
SSH_PORT=2222

declare -A QEMU_ARCH=(
    ["x86_64"]="x86_64"
    ["arm64"]="aarch64"
    ["riscv64"]="riscv64"
)
declare -A MACHINE_TYPE=(
    ["x86_64"]="pc"
    ["arm64"]="virt"
    ["riscv64"]="virt"
)
declare -A EFI_CODE=(
    ["x86_64"]="/usr/share/OVMF/OVMF_CODE_4M.fd"
    ["arm64"]="/usr/share/AAVMF/AAVMF_CODE.fd"
    ["riscv64"]="/usr/share/qemu-efi-riscv64/RISCV_VIRT_CODE.fd"
)
declare -A EFI_VARS=(
    ["x86_64"]="/usr/share/OVMF/OVMF_VARS_4M.fd"
    ["arm64"]="/usr/share/AAVMF/AAVMF_VARS.fd"
    ["riscv64"]="/usr/share/qemu-efi-riscv64/RISCV_VIRT_VARS.fd"
)

QEMU_BIN="qemu-system-${QEMU_ARCH[$ARCH]}"
MACHINE="${MACHINE_TYPE[$ARCH]}"
EFI_FIRMWARE_CODE="${EFI_CODE[$ARCH]}"
EFI_FIRMWARE_VARS="${EFI_VARS[$ARCH]}"

if [[ "$(uname -m)" == "$ARCH" ]]; then
    CPU_MODEL="host"
    ACCEL="kvm"
else
    CPU_MODEL="max"
    ACCEL="tcg"
fi

cp "$SOURCE_IMAGE" "$TARGET_IMAGE"
qemu-img resize -f qcow2 "$TARGET_IMAGE" 30G
cp "$EFI_FIRMWARE_VARS" /tmp/efivars.fd
cloud-localds /tmp/seeds-cloudimg.iso user-data meta-data

/usr/bin/"$QEMU_BIN" \
    -nographic \
    -cpu "$CPU_MODEL" \
    -machine "type=$MACHINE,accel=$ACCEL" \
    -netdev user,id=user.0,hostfwd=tcp::${SSH_PORT}-:22 \
    -device virtio-net,netdev=user.0 \
    -drive file="$EFI_FIRMWARE_CODE",if=pflash,unit=0,format=raw,readonly=on \
    -drive file=/tmp/efivars.fd,if=pflash,unit=1,format=raw \
    -drive file=$TARGET_IMAGE,if=virtio,cache=writeback,discard=ignore,format=qcow2 \
    -drive file=/tmp/seeds-cloudimg.iso,format=raw \
    -m 16384M \
    -smp 8
