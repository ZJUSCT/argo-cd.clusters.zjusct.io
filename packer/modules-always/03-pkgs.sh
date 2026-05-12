#!/usr/bin/env bash
# Install essential packages for image build and daily use

# shellcheck disable=SC1091
source /run/header

# packages with same name across distros
common=(
    fish zsh tmux bash-completion
    vim neovim
    jq fzf ripgrep duf tree file
    curl wget rsync net-tools traceroute
    git git-lfs pkg-config
    btop htop sudo
    zip unzip
    squashfs-tools
    rustup
    pre-commit
    shfmt
)

debian=("${common[@]}"
    "linux-headers-$(uname -r)" dkms
    gpg
    locales
    fd-find
    sshfs
    build-essential
    python3-full python3-pip python3-venv
    zoxide
    starship
    network-manager
    zfs-dkms zfsutils-linux
    firmware-amd-graphics
)

ubuntu=("${debian[@]}")

fedora=("${common[@]}"
    "kernel-devel-$(uname -r | awk -F'-' '{print $1}')"
    gpg
    fd-find
    eza
    sshfs fuse-sshfs
    gcc make
    python3 python3-pip
    NetworkManager
    dnf-plugins-core yum-utils
)

rocky=("${fedora[@]}")

arch=("${common[@]}"
    gnupg
    fd eza
    iputils bind sshfs
    base-devel
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
