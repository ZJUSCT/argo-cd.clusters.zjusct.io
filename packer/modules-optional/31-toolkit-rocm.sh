#!/usr/bin/env bash
# Install AMD ROCm Toolkit
# https://rocm.docs.amd.com/en/latest/
# Supports: Debian, Ubuntu, Fedora, Rocky (x86_64, aarch64)

# shellcheck disable=SC1091
source /run/header

case "$ARCH" in
x86_64 | aarch64) ;;
*)
    echo "ROCm toolkit: unsupported arch $ARCH, skipping"
    exit 0
    ;;
esac

case $ID in
debian | ubuntu | fedora | rocky) ;;
*)
    echo "ROCm toolkit: unsupported distro $ID, skipping"
    exit 0
    ;;
esac

if ! command -v amdgpu-install &>/dev/null; then
    echo "ROCm toolkit: amdgpu-install not found, run 30-driver-amd.sh first, skipping"
    exit 0
fi

amdgpu-install -y --usecase=rocm
