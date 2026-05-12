#!/usr/bin/env bash
# NVIDIA DOCA Driver installation
# https://docs.nvidia.com/doca/sdk/doca-installation-guide-for-linux/index.html
# Supports: Ubuntu, Debian, Rocky Linux (x86_64, aarch64)

# shellcheck disable=SC1091
source /run/header

# Map distro/version to DOCA repo path
# https://linux.mellanox.com/public/repo/doca/
DOCA_VERSION="latest"
DOCA_OS="${ID}${VERSION_ID}"

DOCA_URL="http://linux.mellanox.com/public/repo/doca/${DOCA_VERSION}/${DOCA_OS}/${ARCH}/"

case $ID in
debian | ubuntu)
    add_repo doca "http://linux.mellanox.com/public/repo/doca/GPG-KEY-Mellanox.pub" "${DOCA_URL} ./"
    install_pkg doca-all mlnx-nfsrdma-dkms
    ;;
rocky)
    install -D -m 0644 /dev/stdin /etc/yum.repos.d/doca.repo <<EOF
[doca]
name=DOCA Online Repo
baseurl=http://linux.mellanox.com/public/repo/doca/${DOCA_VERSION}/rhel9/${ARCH}/
enabled=1
gpgcheck=0
EOF
    install_pkg doca-all
    ;;
fedora)
    echo "DOCA driver: not available on fedora."
    exit 1
    ;;
esac
