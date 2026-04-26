#!/usr/bin/env bash
# Cleanup script for packer images

# shellcheck disable=SC1091
source /run/header

echo 'Cleaning up...'

########################################################################
# SSH and User
########################################################################
passwd -d root
# disable ssh password login
sed -i -e 's/^\(PasswordAuthentication\s*\).*$/\1no/' /etc/ssh/sshd_config

########################################################################
# Package manager cleanup
########################################################################
case $ID in
ubuntu | debian)
    apt-get autopurge -y
    apt-get distclean
    ;;
fedora | rocky | arch)
    dnf clean all 2>/dev/null || true
    ;;
esac
cloud-init clean --logs
rm -f /etc/ssh/ssh_host_*
truncate -s 0 /etc/machine-id
