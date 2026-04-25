#!/usr/bin/env bash
# Install essential packages for image build and daily use

# shellcheck disable=SC1091
source /tmp/00-shared.sh

# packages with same name across distros
common=(
    # Shells & terminals
    fish zsh tmux bash-completion

    # Editors
    vim neovim

    # CLI utilities
    jq fzf ripgrep duf tree file

    # Network
    curl wget rsync net-tools traceroute

    # Build essentials
    git git-lfs pkg-config

    # System
    htop sudo

    # Compression
    zip unzip

    # Image & container
    squashfs-tools
)

debian=("${common[@]}"
    # System
    gpg locales

    # CLI utilities
    fd-find

    # Network
    sshfs

    # Build essentials
    build-essential

    # Python
    python3-full python3-pip python3-venv

    network-manager
    zfs-dkms zfsutils-linux
)

ubuntu=("${debian[@]}")

fedora=("${common[@]}"
    # System
    gpg

    # CLI utilities
    fd-find bat eza

    # Network
    sshfs

    # Build essentials
    gcc make

    # Python
    python3 python3-pip

    NetworkManager
    dnf-plugins-core
)

rocky=("${common[@]}"
    # System
    gpg

    # CLI utilities
    fd-find

    # Network (package name differs from common)
    fuse-sshfs

    # Build essentials
    gcc make

    # Python
    python3 python3-pip

    NetworkManager
    yum-utils
)

arch=("${common[@]}"
    # System
    gnupg

    # CLI utilities
    fd bat eza

    # Network
    iputils bind sshfs

    # Build essentials
    base-devel

    # Python
    python python-pip

    networkmanager
)

case $ID in
debian)
    install_pkg "${debian[@]}"
    ;;
ubuntu)
    # Disable unattended-upgrades to avoid dpkg lock contention during image build
    systemctl disable --now unattended-upgrades
    install_pkg "${ubuntu[@]}"
    ;;
fedora) install_pkg "${fedora[@]}" ;;
rocky) install_pkg "${rocky[@]}" ;;
arch) install_pkg "${arch[@]}" ;;
*)
    echo "Unsupported distro: $ID" >&2
    exit 1
    ;;
esac
