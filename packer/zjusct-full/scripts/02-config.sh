#!/usr/bin/env bash
set -xeou pipefail

########################################################################
# Sync rootfs files
#
# We use 'install' instead of 'rsync' or 'cp -a' because:
# - 'install' allows explicit control over permissions and ownership
# - No need to calculate/preserve source permissions (e.g., 0440 for sudoers)
# - Simpler and more predictable: each file has exact perms we specify
########################################################################

# check if source files exist
tree /tmp/rootfs

# systemd overrides
install -D -m 0644 -o root -g root /tmp/rootfs/etc/systemd/system/docker.socket.d/override.conf /etc/systemd/system/docker.socket.d/override.conf
install -D -m 0644 -o root -g root /tmp/rootfs/etc/systemd/system/sssd.service.d/override.conf /etc/systemd/system/sssd.service.d/override.conf
install -D -m 0644 -o root -g root /tmp/rootfs/etc/systemd/system/otelcol-contrib.service.d/override.conf /etc/systemd/system/otelcol-contrib.service.d/override.conf

# otelcol-contrib
install -D -m 0640 -o root -g root /tmp/rootfs/etc/otelcol-contrib/config.yaml /etc/otelcol-contrib/config.yaml

########################################################################
# Systemd
########################################################################

# Disable systemd socket activation for SSSD responders
# FreeIPA client already configures nss/pam/ssh/sudo in sssd.conf services line
# Socket activation conflicts with this configuration
systemctl disable --now \
    kubelet \
    sssd-nss.socket \
    sssd-pam.socket \
    sssd-pam-priv.socket \
    sssd-ssh.socket \
    sssd-sudo.socket \
    sssd-autofs.socket \
    sssd-pac.socket 2>/dev/null || true

########################################################################
# Domain Control
########################################################################

groupdel docker # use FreeIPA group
