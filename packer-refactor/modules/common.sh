#!/usr/bin/env bash
# Common functions for packer scripts

set -euo pipefail

########################################################################
# OS independent #
########################################################################
export http_proxy=http://172.28.0.4:3128
export HTTP_PROXY=http://172.28.0.4:3128
export https_proxy=http://172.28.0.4:3128
export HTTPS_PROXY=http://172.28.0.4:3128
# https://unix.stackexchange.com/questions/351557/on-what-linux-distributions-can-i-rely-on-the-presence-of-etc-os-release
# https://github.com/which-distro/os-release
# shellcheck disable=SC1091
source /etc/os-release

########################################################################
# OS specific
########################################################################
case $ID in
ubuntu | debian)
    export DEBIAN_FRONTEND=noninteractive
    ;;
esac

install_pkg() {
    case $ID in
    ubuntu | debian)
        apt-get install "$@"
        ;;
    openEuler)
        dnf install "$@"
        ;;
    arch)
        pacman -S "$@"
        ;;
    *)
        echo "Unknown distribution: $ID"
        exit 1
        ;;
    esac
}

########################################################################
# runtime immutable variables
# appended by 00-bootstrap.sh
########################################################################
