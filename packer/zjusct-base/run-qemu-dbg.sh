#!/usr/bin/env bash

SSH_PORT=2222

SOURCE_IMAGE=${1:-output/zjusct-base.qcow2}
TARGET_IMAGE="/tmp/debug.qcow2"
cp "$SOURCE_IMAGE" "$TARGET_IMAGE"
/usr/bin/qemu-system-x86_64 \
    -nographic \
    -cpu host \
    -machine type=pc,accel=kvm \
    -netdev user,id=user.0,hostfwd=tcp::${SSH_PORT}-:22 \
    -device virtio-net,netdev=user.0 \
    -drive file=$TARGET_IMAGE,if=virtio,cache=writeback,discard=ignore,format=qcow2 \
    -name debug \
    -m 16384M \
    -smp 8

    #-drive file=/usr/share/OVMF/OVMF_CODE.fd,if=pflash,unit=0,format=raw,readonly=on \
    #-drive file=output/efivars.fd,if=pflash,unit=1,format=raw \
