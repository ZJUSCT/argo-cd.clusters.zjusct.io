#!/usr/bin/env bash
# shellcheck disable=SC1091
source /tmp/00-shared.sh

DOCKER_MIRROR=https://$MIRROR/docker-ce

########################################################################
# Docker
########################################################################

install_docker() {
    case $ID in
    ubuntu | debian)
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL "$DOCKER_MIRROR/linux/$ID/gpg" -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
        cat >/etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.asc] $DOCKER_MIRROR/linux/$ID $VERSION_CODENAME stable
EOF
        apt-get update
        install_pkg docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        ;;
    fedora)
        dnf -y install dnf-plugins-core
        dnf config-manager --add-repo "$DOCKER_MIRROR/linux/fedora/docker-ce.repo"
        dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
        ;;
    arch)
        install_pkg docker docker-buildx docker-compose containerd
        ;;
    openEuler)
        install_pkg docker
        ;;
    *)
        echo "Docker: unsupported distro $ID"
        exit 1
        ;;
    esac
}

if [ "$ARCH" = "riscv64" ]; then
    # docker-ce has no riscv64 build, fall back to distro package
    install_pkg docker.io lxcfs
else
    install_docker
fi

install_pkg lxcfs
systemctl enable lxcfs docker

mkdir -p /etc/docker
cat >/etc/docker/daemon.json <<EOF
{
  "log-opts": {
    "tag": "container.name={{.Name}} container.id={{.ID}} container.image.name={{.ImageName}} container.runtime={{.DaemonName}}"
  }
}
EOF

########################################################################
# Dive — container image explorer
# https://github.com/wagoodman/dive
# Supports: amd64, arm64
########################################################################

case $ARCH in
x86_64 | amd64)   dive_arch="amd64" ;;
aarch64 | arm64)  dive_arch="arm64" ;;
*)
    echo "Dive: unsupported arch $ARCH, skipping"
    ;;
esac

if [ -n "${dive_arch:-}" ]; then
    install_pkg_from_github "wagoodman/dive" "dive_*_linux_${dive_arch}.deb"
fi

########################################################################
# Apptainer
# https://github.com/apptainer/apptainer
# Supports: amd64 only (no arm64/riscv64 builds)
########################################################################

case $ARCH in
x86_64 | amd64)
    case $ID in
    ubuntu | debian)
        install_pkg_from_github "apptainer/apptainer" "apptainer_*_amd64.deb"
        ;;
    fedora | openEuler)
        install_pkg_from_github "apptainer/apptainer" "apptainer_*_x86_64.rpm"
        ;;
    arch)
        install_pkg apptainer
        ;;
    esac
    ;;
*)
    echo "Apptainer: unsupported arch $ARCH, skipping"
    ;;
esac
