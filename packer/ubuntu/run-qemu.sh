#!/usr/bin/env bash

set -xe

TARGET_IMAGE="${1:-output/ubuntu.qcow2}"
SOURCE_IMAGE="questing-server-cloudimg-amd64.img"

mkdir -p "$(dirname "$TARGET_IMAGE")"
qemu-img convert -O qcow2 "$SOURCE_IMAGE" "$TARGET_IMAGE"
qemu-img resize -f qcow2 "$TARGET_IMAGE" 20G
cp /usr/share/OVMF/OVMF_VARS.fd output/efivars.fd

qemu-system-x86_64 \
    -nographic \
   -device virtio-net,netdev=user.0 \
   -boot c \
   -name ubuntu.qcow2 \
   -machine type=pc,accel=kvm \
   -smp 4 \
   -drive if=pflash,format=raw,id=ovmf_code,readonly=on,file=/usr/share/OVMF/OVMF_CODE.fd \
   -drive if=pflash,format=raw,id=ovmf_vars,file=output/efivars.fd \
   -drive file=output/ubuntu.qcow2,format=qcow2 \
   -drive file=seeds-cloudimg.iso,format=raw \
   -m 16384M \
   -netdev user,id=user.0,hostfwd=tcp::4250-:22
