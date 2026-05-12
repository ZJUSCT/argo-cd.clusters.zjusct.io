#!/usr/bin/env bash
# Install AMD GPU driver and amdgpu-install script
# https://www.amd.com/en/support/download/linux-drivers.html
# Supports: Debian, Ubuntu, Fedora, Rocky (x86_64, aarch64)

# shellcheck disable=SC1091
source /run/header

case "$ARCH" in
x86_64 | aarch64) ;;
*)
    echo "AMD driver: unsupported arch $ARCH, skipping"
    exit 0
    ;;
esac

# Map distro/version to closest AMD-supported distro for installer package
# AMD only publishes installer packages for Ubuntu and RHEL/EL
# For unsupported distros, use the closest compatible installer
amd_installer_dir=""
case $ID in
debian | ubuntu)
    case $VERSION_ID in
    13 | 26.04)
        # Debian 13 / Ubuntu 26.04: use Ubuntu 24.04 (noble) installer
        amd_installer_dir="ubuntu/noble"
        ;;
    24.04)
        amd_installer_dir="ubuntu/noble"
        ;;
    22.04)
        amd_installer_dir="ubuntu/jammy"
        ;;
    *)
        echo "AMD driver: $ID $VERSION_ID not supported, skipping"
        exit 0
        ;;
    esac
    ;;
fedora | rocky)
    # Find latest EL directory for the major version
    # Fedora 43 maps to EL9, Rocky 10 maps to EL10
    case $VERSION_ID in
    43 | 9.*)
        el_major=9
        ;;
    10)
        el_major=10
        ;;
    *)
        echo "AMD driver: $ID $VERSION_ID not supported, skipping"
        exit 0
        ;;
    esac
    amd_installer_dir=$(curl -s "http://repo.radeon.com/amdgpu-install/latest/el/" |
        grep -oP "href=\"\K${el_major}\.[0-9]+/" | sort -V | tail -1)
    if [ -n "$amd_installer_dir" ]; then
        amd_installer_dir="el/${amd_installer_dir%/}"
    fi
    ;;
*)
    echo "AMD driver: unsupported distro $ID, skipping"
    exit 0
    ;;
esac

if [ -z "$amd_installer_dir" ]; then
    echo "AMD driver: no installer package found for $ID $VERSION_ID, skipping"
    exit 0
fi

# --- Install amdgpu-install package ---
case $ID in
debian | ubuntu)
    pkg_name=$(curl -s "http://repo.radeon.com/amdgpu-install/latest/${amd_installer_dir}/" |
        grep -oP 'amdgpu-install_[^"]*_all\.deb' | head -1)
    if [ -z "$pkg_name" ]; then
        echo "AMD driver: no deb found in $amd_installer_dir, skipping"
        exit 0
    fi
    curl -o /tmp/amdgpu-install.deb \
        "http://repo.radeon.com/amdgpu-install/latest/${amd_installer_dir}/${pkg_name}"
    dpkg -i /tmp/amdgpu-install.deb
    rm -f /tmp/amdgpu-install.deb
    apt-get update
    ;;
fedora | rocky)
    pkg_name=$(curl -s "http://repo.radeon.com/amdgpu-install/latest/${amd_installer_dir}/" |
        grep -oP 'amdgpu-install-[^"]*\.noarch\.rpm' | head -1)
    if [ -z "$pkg_name" ]; then
        echo "AMD driver: no rpm found in $amd_installer_dir, skipping"
        exit 0
    fi
    dnf install -y \
        "http://repo.radeon.com/amdgpu-install/latest/${amd_installer_dir}/${pkg_name}"
    ;;
esac

# --- Install AMD GPU driver (All-Open use case) ---
amdgpu-install -y --usecase=graphics
