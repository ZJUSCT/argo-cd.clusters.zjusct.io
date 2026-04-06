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

# MOTD
rm -f /etc/update-motd.d/*
install -D -m 0755 -o root -g root /tmp/rootfs/etc/update-motd.d/00-nice-motd /etc/update-motd.d/00-nice-motd
install -D -m 0644 -o root -g root /tmp/rootfs/etc/motd /etc/motd

# systemd overrides
install -D -m 0644 -o root -g root /tmp/rootfs/etc/systemd/system/otelcol-contrib.service.d/override.conf /etc/systemd/system/otelcol-contrib.service.d/override.conf

# otelcol-contrib
install -D -m 0640 -o root -g root /tmp/rootfs/etc/otelcol-contrib/config.yaml /etc/otelcol-contrib/config.yaml

# mount local disks
install -D -m 0755 -o root -g root /tmp/rootfs/usr/local/bin/mount-local.sh /usr/local/bin/mount-local.sh
install -D -m 0644 -o root -g root /tmp/rootfs/etc/systemd/system/mount-local.service /etc/systemd/system/mount-local.service
systemctl enable mount-local

# audit
install -D -m 0640 -o root -g adm /tmp/rootfs/etc/audit/rules.d/zjusct.rules /etc/audit/rules.d/zjusct.rules

# docker
install -D -m 0644 -o root -g root /tmp/rootfs/etc/docker/daemon.json /etc/docker/daemon.json

# sudoers (must be 0440)
install -D -m 0440 -o root -g root /tmp/rootfs/etc/sudoers.d/audit /etc/sudoers.d/audit

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

# Keep local docker group with same GID as FreeIPA group for boot-time fallback
# SocketGroup=docker in docker.socket needs the group to exist before SSSD is online
# SSSD provides group membership; local group provides the GID
groupmod -g 1109200066 docker
