#!/usr/bin/env bash
# Configure mirrors for faster package installation and updates

# shellcheck disable=SC1091
source /tmp/00-shared.sh

########################################################################
# HTTPS Cache Proxy Certificate
# While this work is meant to be done in cloud-init,
# the ca_certs module does not support all distros we target
########################################################################

case "$ID" in
rocky)
    # TODO: Rocky 9 ships cloud-init 24.4 which does not verify the ca_certs
    # module for this distro, so the proxy CA is not installed by cloud-init.
    # Remove this when Rocky ships higher version of cloud-init which supports it.
    install -D -m 0644 /tmp/squid.crt /etc/pki/ca-trust/source/anchors/proxy-ca.crt
    update-ca-trust
    ;;
arch)
    # cloud-init ca_certs module does not support Arch, install proxy CA manually
    install -D -m 0644 /tmp/squid.crt /etc/ca-certificates/trust-source/anchors/proxy-ca.crt
    update-ca-trust
    ;;
esac

########################################################################
# Distro package manager mirrors
########################################################################

case $ID in
debian | ubuntu)
    find /etc/apt -type f \( -name '*.list' -o -name '*.sources' \) \
        -exec sed -i -e "s/[a-z]*\.debian\.org/mirrors.cernet.edu.cn/g; s/[a-z]*\.ubuntu\.com/$MIRROR/g" {} +
    # shellcheck disable=SC2154
    install -D -m 0644 /dev/stdin /etc/apt/apt.conf.d/99proxy <<EOF
Acquire::http::Proxy "$http_proxy";
Acquire::https::Proxy "$https_proxy";
EOF
    case $ID in
    debian)
        # Enable contrib, non-free, non-free-firmware components for DKMS and NVIDIA drivers
        find /etc/apt -type f \( -name '*.list' -o -name '*.sources' \) \
            -exec sed -i -e 's/ main / main contrib non-free non-free-firmware /g; s/ main$/ main contrib non-free non-free-firmware/g' {} +
        ;;
    esac
    apt-get update
    ;;
fedora)
    install -D -m 0644 /dev/stdin /etc/dnf/dnf.conf.d/99proxy.conf <<EOF
[main]
proxy=$http_proxy
EOF
    sed -e 's|^metalink=|#metalink=|g' \
        -e 's|^#baseurl=http://download.example/pub/fedora/linux|baseurl=https://'"$MIRROR"'/fedora|g' \
        -i.bak \
        /etc/yum.repos.d/fedora.repo \
        /etc/yum.repos.d/fedora-updates.repo
    dnf makecache
    ;;
rocky)
    install -D -m 0644 /dev/stdin /etc/dnf/dnf.conf.d/99proxy.conf <<EOF
[main]
proxy=$http_proxy
EOF
    # shellcheck disable=SC2016
    sed -i \
        -e 's|^mirrorlist=|#mirrorlist=|g' \
        -e 's|^#baseurl=http://dl.rockylinux.org/$contentdir|baseurl=https://'"$MIRROR"'/rocky|g' \
        /etc/yum.repos.d/rocky*.repo
    # Enable CRB (CodeReady Builder) for additional packages, equivalent to
    # Debian contrib/non-free
    dnf config-manager --set-enabled crb
    # EPEL provides community packages not in upstream repos
    install_pkg epel-release
    sed -i "s|https://download\.fedoraproject\.org/pub/epel|https://$MIRROR/epel|g" \
        /etc/yum.repos.d/epel*.repo
    dnf makecache
    ;;
arch)
    sed -i "1i Server = https://$MIRROR/archlinux/\$repo/os/\$arch" /etc/pacman.d/mirrorlist
    pacman -Syy
    ;;
*)
    echo "Unsupported distro: $ID"
    exit 1
    ;;
esac

########################################################################
# language-specific package managers
########################################################################

install -D -m 0644 /dev/stdin /etc/npmrc <<EOF
registry=https://registry.npmmirror.com/
EOF

install -D -m 0644 /dev/stdin /etc/pip.conf <<EOF
[global]
index-url = https://$MIRROR/pypi/web/simple
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
