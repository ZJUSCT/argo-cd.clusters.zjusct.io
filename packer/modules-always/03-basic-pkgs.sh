#!/usr/bin/env bash
# Install basic packages essential for image build and daily use
# shellcheck disable=SC1091
source /tmp/00-shared.sh

common=(
    # Shells & terminals
    fish zsh tmux bash-completion

    # Editors
    vim neovim

    # CLI utilities
    jq fzf ripgrep duf tree file

    # Network
    curl wget rsync net-tools traceroute sshfs

    # Build essentials
    git git-lfs pkg-config

    # System
    gpg htop sudo

    # Compression
    zip unzip

    # Image & container
    squashfs-tools
)

debian=("${common[@]}"
    # CLI utilities
    fd-find

    # Build essentials
    build-essential

    # Python
    python3-full python3-pip python3-venv
)

ubuntu=("${debian[@]}")

fedora=("${common[@]}"
    # CLI utilities
    fd-find bat eza

    # Build essentials
    gcc make

    # Python
    python3 python3-pip
)

arch=("${common[@]}"
    # CLI utilities
    fd bat eza

    # Network
    iputils bind

    # Build essentials
    base-devel

    # Python
    python python-pip
)

case $ID in
debian)  install_pkg "${debian[@]}" ;;
ubuntu)  install_pkg "${ubuntu[@]}" ;;
fedora)  install_pkg "${fedora[@]}" ;;
arch)    install_pkg "${arch[@]}" ;;
*)       echo "Unsupported distro: $ID" >&2; exit 1 ;;
esac
