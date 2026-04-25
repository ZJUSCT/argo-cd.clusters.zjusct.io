#!/usr/bin/env bash
# Container Runtimes and tools

# shellcheck disable=SC1091
source /tmp/00-shared.sh

########################################################################
# Podman
########################################################################

install_pkg podman

########################################################################
# Docker
########################################################################

DOCKER_MIRROR=https://$MIRROR/docker-ce

case $ARCH in
riscv64)
    # docker-ce has no riscv64 build, fall back to distro package
    install_pkg docker.io
    ;;
*)
    case $ID in
    ubuntu | debian)
        add_repo "docker" "$DOCKER_MIRROR/linux/$ID/gpg" "$DOCKER_MIRROR/linux/$ID $VERSION_CODENAME stable"
        install_pkg docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        ;;
    fedora | rocky)
        dnf -y install dnf-plugins-core
        add_repo "$DOCKER_MIRROR/linux/fedora/docker-ce.repo"
        dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
        ;;
    arch)
        install_pkg docker docker-buildx docker-compose containerd
        ;;
    *)
        echo "Docker: unsupported distro $ID"
        exit 1
        ;;
    esac
    ;;
esac

mkdir -p /etc/docker
cat >/etc/docker/daemon.json <<EOF
{
  "log-opts": {
    "tag": "container.name={{.Name}} container.id={{.ID}} container.image.name={{.ImageName}} container.runtime={{.DaemonName}}"
  }
}
EOF

########################################################################
# LXC
########################################################################

case $ID in
ubuntu | debian)
    install_pkg lxc lxcfs libvirt0 libpam-cgfs bridge-utils uidmap
    ;;
fedora | rocky)
    install_pkg lxc lxc-templates
    ;;
arch)
    install_pkg lxc arch-install-scripts
esac

########################################################################
# Apptainer
# https://github.com/apptainer/apptainer
########################################################################

case $ARCH in
x86_64)
    case $ID in
    ubuntu | debian)
        # Prefer distro-specific build (e.g. apptainer_1.4.5-trixie+_amd64.deb)
        # which has correct dependency versions, fall back to generic build
        if ! pkg=$(get_github_release_asset "apptainer/apptainer" \
            "^apptainer_[0-9]+\\.[0-9]+\\.[0-9]+-${VERSION_CODENAME}\\+?_amd64\\.deb$" 2>/dev/null); then
            pkg=$(get_github_release_asset "apptainer/apptainer" \
                "^apptainer_[0-9]+\\.[0-9]+\\.[0-9]+_amd64\\.deb$")
        fi
        install_pkg "$pkg"
        rm -f "$pkg"
        ;;
    fedora | rocky)
        install_pkg apptainer
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
