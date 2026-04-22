#!/usr/bin/env bash
set -xeou pipefail

echo 'Cleaning up...'

########################################################################
# SSH and User
########################################################################
passwd -d root
# disable ssh password login
sed -i -e 's/^\(PasswordAuthentication\s*\).*$/\1no/' /etc/ssh/sshd_config

apt-get autoremove -y --purge
apt-get clean
cloud-init clean --logs
rm -f /etc/ssh/ssh_host_*
truncate -s 0 /etc/machine-id
