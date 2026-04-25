#!/usr/bin/env bash
# NVIDIA DOCA Driver installation
# https://docs.nvidia.com/doca/sdk/doca-installation-guide-for-linux/index.html
# Supports: Ubuntu, Debian, Rocky Linux (x86_64, aarch64)

# shellcheck disable=SC1091
source /tmp/00-shared.sh

# Map distro/version to DOCA repo path
# https://linux.mellanox.com/public/repo/doca/
DOCA_VERSION="latest"
DOCA_OS="${ID}${VERSION_ID}"

DOCA_URL="https://linux.mellanox.com/public/repo/doca/${DOCA_VERSION}/${DOCA_OS}/${ARCH}/"

# Verify the repo exists before proceeding
if ! curl -fsSL "${DOCA_URL}" >/dev/null 2>&1; then
    echo "DOCA: repo not found at ${DOCA_URL}"
    echo "Check if DOCA supports $ID $VERSION_ID for $ARCH"
    exit 1
fi

case $ID in
debian | ubuntu)
    add_repo doca "https://linux.mellanox.com/public/repo/doca/GPG-KEY-Mellanox.pub" "${DOCA_URL} ./"
    # Pin DOCA repo higher to resolve version conflicts with CUDA repo (e.g. mft)
    echo -e "Package: *\nPin: origin linux.mellanox.com\nPin-Priority: 900" \
        >/etc/apt/preferences.d/doca
    install_pkg "linux-headers-$(uname -r)" dkms
    install_pkg doca-all
    ;;
rocky)
    install -D -m 0644 /dev/stdin /etc/yum.repos.d/doca.repo <<EOF
[doca]
name=DOCA Online Repo
baseurl=https://linux.mellanox.com/public/repo/doca/${DOCA_VERSION}/rhel9/${ARCH}/
enabled=1
gpgcheck=0
EOF
    install_pkg doca-all
    ;;
esac
