#!/usr/bin/env bash
# Install NVIDIA CUDA Toolkit
# https://docs.nvidia.com/cuda/cuda-installation-guide-linux/
# shellcheck disable=SC1091
source /tmp/00-shared.sh

case "$ARCH" in
x86_64 | aarch64) ;;
*)
    echo "CUDA toolkit: unsupported arch $ARCH, skipping"
    exit 0
    ;;
esac

case $ID in
debian)
    case $VERSION_ID in
    12)
        cuda_repo="debian12"
        ;;
    13)
        cuda_repo="debian13"
        ;;
    *)
        echo "CUDA toolkit: $ID $VERSION_ID not in CUDA support list, skipping"
        exit 0
        ;;
    esac
    ;;
ubuntu)
    case $VERSION_ID in
    22.04) cuda_repo="ubuntu2204" ;;
    24.04) cuda_repo="ubuntu2404" ;;
    *)
        echo "CUDA toolkit: $ID $VERSION_ID not in CUDA support list, skipping"
        exit 0
        ;;
    esac
    ;;
fedora)
    case $VERSION_ID in
    40 | 41 | 42) cuda_repo="fedora${VERSION_ID}" ;;
    *)
        echo "CUDA toolkit: $ID $VERSION_ID not in CUDA support list, skipping"
        exit 0
        ;;
    esac
    ;;
*)
    echo "CUDA toolkit: unsupported distro $ID, skipping"
    exit 0
    ;;
esac

# Ensure cuda-keyring is installed
case $ARCH in
x86_64) nvidia_arch="x86_64" ;;
aarch64) nvidia_arch="sbsa" ;;
esac

case $ID in
debian | ubuntu)
    if ! dpkg -l cuda-keyring 2>/dev/null | grep -q ^ii; then
        curl -fsSL "https://developer.download.nvidia.com/compute/cuda/repos/${cuda_repo}/${nvidia_arch}/cuda-keyring_1.1-1_all.deb" \
            -o /tmp/cuda-keyring.deb
        dpkg -i /tmp/cuda-keyring.deb
        rm -f /tmp/cuda-keyring.deb
        apt-get update
    fi
    ;;
fedora)
    if ! rpm -q cuda-keyring 2>/dev/null; then
        dnf install -y "https://developer.download.nvidia.com/compute/cuda/repos/${cuda_repo}/${nvidia_arch}/cuda-keyring-1.1-1.noarch.rpm" || {
            echo "CUDA toolkit: failed to install cuda-keyring for fedora $VERSION_ID, skipping"
            exit 0
        }
    fi
    ;;
esac

case $ID in
debian | ubuntu)
    install_pkg cuda-toolkit
    ;;
fedora)
    dnf install -y cuda-toolkit
    ;;
esac
