#!/usr/bin/env bash
# Configure locale and timezone settings

# shellcheck disable=SC1091
source /tmp/00-shared.sh

case $ID in
ubuntu | debian)
    echo 'en_US.UTF-8 UTF-8' >/etc/locale.gen
    locale-gen en_US.UTF-8 zh_CN.UTF-8
    update-locale LANG=en_US.UTF-8
    ;;
fedora | rocky)
    dnf install -y glibc-langpack-en glibc-langpack-zh
    localectl set-locale LANG=en_US.UTF-8
    ;;
arch)
    sed -i 's/^#\(en_US\.UTF-8\)/\1/' /etc/locale.gen
    sed -i 's/^#\(zh_CN\.UTF-8\)/\1/' /etc/locale.gen
    locale-gen
    ;;
*)
    echo "Unsupported distro: $ID"
    exit 1
    ;;
esac

timedatectl set-timezone Asia/Shanghai
