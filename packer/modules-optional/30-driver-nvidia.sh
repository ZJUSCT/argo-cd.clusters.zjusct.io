#!/usr/bin/env bash
# Install NVIDIA GPU driver and nvidia-container-toolkit
# https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html
# shellcheck disable=SC1091
source /run/header

case "$ARCH" in
x86_64 | aarch64) ;;
*)
    echo "NVIDIA driver: unsupported arch $ARCH, skipping"
    exit 0
    ;;
esac

# Map distro/version to NVIDIA repo codename
# https://developer.download.nvidia.com/compute/cuda/repos/
nvidia_repo_dir=""
case $ID in
debian) nvidia_repo_dir="debian$(echo "$VERSION_ID" | tr -d .)" ;;
ubuntu) nvidia_repo_dir="ubuntu$(echo "$VERSION_ID" | tr -d .)" ;;
fedora) nvidia_repo_dir="fedora$(echo "$VERSION_ID" | tr -d .)" ;;
esac

case $ARCH in
x86_64) nvidia_arch="x86_64" ;;
aarch64) nvidia_arch="sbsa" ;;
esac

if [ -n "$nvidia_repo_dir" ]; then
    nvidia_repo="${nvidia_repo_dir}/${nvidia_arch}"
else
    nvidia_repo=""
fi

# --- Install cuda-keyring (idempotent) ---
ensure_cuda_keyring() {
    case $ID in
    debian | ubuntu)
        if dpkg -l cuda-keyring 2>/dev/null | grep -q ^ii; then
            return 0
        fi
        curl -fsSL "http://developer.download.nvidia.com/compute/cuda/repos/${nvidia_repo}/cuda-keyring_1.1-1_all.deb" \
            -o /tmp/cuda-keyring.deb || return 1
        dpkg -i /tmp/cuda-keyring.deb
        rm -f /tmp/cuda-keyring.deb
        apt-get update
        ;;
    fedora)
        if rpm -q cuda-keyring 2>/dev/null; then
            return 0
        fi
        dnf install -y "http://developer.download.nvidia.com/compute/cuda/repos/${nvidia_repo}/cuda-keyring-1.1-1.noarch.rpm"
        ;;
    *)
        return 1
        ;;
    esac
}

# --- Install nvidia-container-toolkit from nvidia.github.io ---
install_nvidia_container_toolkit() {
    case $ID in
    debian | ubuntu)
        curl -fsSL http://nvidia.github.io/libnvidia-container/gpgkey |
            gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
        curl -fsSL http://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list |
            sed "s#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g" |
            tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
        apt-get update
        install_pkg nvidia-container-toolkit
        ;;
    fedora | rocky)
        add_repo "http://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo" \
            install_pkg nvidia-container-toolkit
        ;;
    *)
        echo "nvidia-container-toolkit: unsupported distro $ID, skipping"
        ;;
    esac
}

# --- Main ---
case $ID in
debian | ubuntu)
    ensure_cuda_keyring
    case $ID in
    debian) install_pkg nvidia-open ;;
    ubuntu) install_pkg nvidia-open ;;
    esac
    install_nvidia_container_toolkit
    ;;
fedora)
    ensure_cuda_keyring
    install_pkg nvidia-driver-open
    install_nvidia_container_toolkit
    ;;
arch)
    pacman -Syu --noconfirm nvidia-open nvidia-utils
    # nvidia-container-toolkit available in AUR, skip
    ;;
*)
    echo "NVIDIA driver: unsupported distro $ID, skipping"
    exit 0
    ;;
esac

cat >/etc/modprobe.d/nvidia-perf.conf <<EOF
options nvidia NVreg_RestrictProfilingToAdminUsers=0
EOF
