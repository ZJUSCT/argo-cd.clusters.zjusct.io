#!/usr/bin/env bash
# shellcheck disable=SC1091
source /tmp/00-shared.sh

case $ID in
debian)
    # Debian 12+ cloud images use DEB822 format
    if [ -f /etc/apt/sources.list.d/debian.sources ]; then
        sed -i "s|deb.debian.org|$MIRROR|g" /etc/apt/sources.list.d/debian.sources
    elif [ -f /etc/apt/sources.list ]; then
        sed -i "s|deb.debian.org|$MIRROR|g" /etc/apt/sources.list
    fi
    apt-get update
    ;;
ubuntu)
    case $ARCH in
    x86_64 | amd64)
        repo="ubuntu"
        ;;
    *)
        repo="ubuntu-ports"
        ;;
    esac

    if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
        # DEB822 format (Ubuntu 24.04+)
        sed -i "s|archive.ubuntu.com|$MIRROR/$repo|g; s|ports.ubuntu.com|$MIRROR/$repo|g" /etc/apt/sources.list.d/ubuntu.sources
    elif [ -f /etc/apt/sources.list ]; then
        # One-Line format (Ubuntu < 24.04)
        sed -i "s|archive.ubuntu.com/ubuntu/|$MIRROR/$repo/|g; s|ports.ubuntu.com/ubuntu/|$MIRROR/$repo/|g" /etc/apt/sources.list
    fi
    ;;
fedora)
    sed -i \
        -e 's|^metalink=|#metalink=|g' \
        -e "s|download.example/pub/fedora/linux|$MIRROR/fedora|g" \
        /etc/yum.repos.d/fedora.repo \
        /etc/yum.repos.d/fedora-updates.repo
    dnf makecache
    ;;
arch)
    sed -i "1i Server = $MIRROR/archlinux/\$repo/os/\$arch" /etc/pacman.d/mirrorlist
    pacman -Syy
    ;;
*)
    echo "Unsupported distro: $ID"
    exit 1
    ;;
esac

########################################################################
# Prepare mirrors for language-specific package managers
########################################################################

install -D -m 0644 /dev/stdin /etc/npmrc <<EOF
registry=https://registry.npmmirror.com/
EOF

install -D -m 0644 /dev/stdin /etc/pip.conf <<EOF
[global]
index-url = https://$MIRROR/pypi/web/simple
EOF

install -D -m 0644 /dev/stdin /etc/uv/uv.toml <<EOF
[[index]]
url = "https://$MIRROR/pypi/web/simple/"
default = true
EOF

install -D -m 0644 /dev/stdin "$CONDA_PATH/.condarc" <<EOF
auto_activate_base: false
channels:
  - defaults
show_channel_urls: true
default_channels:
  - https://$MIRROR/anaconda/pkgs/main
  - https://$MIRROR/anaconda/pkgs/r
  - https://$MIRROR/anaconda/pkgs/msys2
custom_channels:
  conda-forge: https://$MIRROR/anaconda/cloud
  msys2: https://$MIRROR/anaconda/cloud
  bioconda: https://$MIRROR/anaconda/cloud
  menpo: https://$MIRROR/anaconda/cloud
  pytorch: https://$MIRROR/anaconda/cloud
  pytorch-lts: https://$MIRROR/anaconda/cloud
  simpleitk: https://$MIRROR/anaconda/cloud
  nvidia: https://$MIRROR/anaconda/cloud
EOF

install -D -m 0644 /dev/stdin /etc/profile.d/rustup.sh <<EOF
export RUSTUP_UPDATE_ROOT=https://$MIRROR/rustup/rustup
export RUSTUP_DIST_SERVER=https://$MIRROR/rustup/dist
EOF

install -D -m 0644 /dev/stdin /etc/cargo/config <<EOF
[source.crates-io]
replace-with = 'mirror'

[source.mirror]
registry = "sparse+https://$MIRROR/crates.io-index/"

[registries.mirror]
index = "sparse+https://$MIRROR/crates.io-index/"
EOF
