#!/usr/bin/env bash
set -xeou pipefail

SOURCE_IMAGE=$1
TARGET_IMAGE="/tmp/debug.qcow2"
SSH_PORT=2222

cp "$SOURCE_IMAGE" "$TARGET_IMAGE"

# qemu-img resize -f qcow2 "$TARGET_IMAGE" 30G
cp /usr/share/OVMF/OVMF_VARS.fd /tmp/efivars.fd
cloud-localds /tmp/seeds-cloudimg.iso user-data meta-data

/usr/bin/qemu-system-x86_64 \
    -nographic \
    -cpu host \
    -machine type=pc,accel=kvm \
    -netdev user,id=user.0,hostfwd=tcp::${SSH_PORT}-:22 \
    -device virtio-net,netdev=user.0 \
    -drive file=/usr/share/OVMF/OVMF_CODE.fd,if=pflash,unit=0,format=raw,readonly=on \
    -drive file=/tmp/efivars.fd,if=pflash,unit=1,format=raw \
    -drive file=$TARGET_IMAGE,if=virtio,cache=writeback,discard=ignore,format=qcow2 \
    -drive file=/tmp/seeds-cloudimg.iso,format=raw \
    -name debug \
    -m 16384M \
    -smp 8
