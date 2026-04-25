#!/usr/bin/env bash
# ZJUSCT cluster specific configuration

# shellcheck disable=SC1091
source /tmp/00-shared.sh

########################################################################
# FreeIPA client dependencies
# Enrolls this node into an IPA cluster via `ipa-client-install`
########################################################################

case $ID in
ubuntu | debian)
    install_pkg freeipa-client sssd-ldap sssd-tools libsss-sudo ldap-utils autofs
    ;;
fedora)
    install_pkg freeipa-client sssd-tools autofs
    ;;
arch)
    echo "FreeIPA client: not available on arch, skipping"
    exit 0
    ;;
*)
    echo "FreeIPA client: unsupported distro $ID"
    exit 1
    ;;
esac

# Disable systemd socket activation for SSSD responders
# FreeIPA client configures nss/pam/ssh/sudo directly in sssd.conf;
# socket activation conflicts with this configuration.
systemctl disable \
    sssd-nss.socket \
    sssd-pam.socket \
    sssd-ssh.socket \
    sssd-sudo.socket \
    sssd-autofs.socket \
    sssd-pac.socket \
    2>/dev/null || true

# Keep local docker group with same GID as FreeIPA group for boot-time fallback
# SocketGroup=docker in docker.socket needs the group to exist before SSSD is online
# SSSD provides group membership; local group provides the GID
groupmod -g 1109200066 docker

##########################################################################
# Ceph
##########################################################################
case $ID in
ubuntu | debian | fedora | rocky)
    install_pkg ceph-common
    ;;
*)
    echo "Ceph client: unsupported distro $ID, skipping"
    ;;
esac

##########################################################################
# HTTP/HTTPS cache proxy
##########################################################################
case $ID in
debian | ubuntu)
    # shellcheck disable=SC2154
    install -D -m 0644 /dev/stdin /etc/apt/apt.conf.d/99proxy <<EOF
Acquire::http::Proxy "$http_proxy";
Acquire::https::Proxy "$https_proxy";
EOF
    ;;
fedora | rocky)
    install -D -m 0644 /dev/stdin /etc/dnf/dnf.conf.d/99proxy.conf <<EOF
[main]
proxy=$http_proxy
EOF
    ;;
esac
