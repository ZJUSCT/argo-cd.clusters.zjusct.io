#!/usr/bin/env bash

OUTPUT=${1:-output/zjusct-base.qcow2}
cp "$OUTPUT" /tmp/cloud-init.qcow2
/usr/bin/qemu-system-x86_64 \
    -nographic \
    -drive file=/tmp/cloud-init.qcow2,if=ide,cache=writeback,discard=ignore,format=qcow2 \
    -drive file=/usr/share/OVMF/OVMF_CODE.fd,if=pflash,unit=0,format=raw,readonly=on \
    -drive file=output/efivars.fd,if=pflash,unit=1,format=raw \
    -name cloud-init.qcow2 \
    -machine type=pc,accel=kvm \
    -netdev user,id=user.0,hostfwd=tcp::4058-:22 \
    -m 16384M \
    -smp 8 \
    -device virtio-net,netdev=user.0
