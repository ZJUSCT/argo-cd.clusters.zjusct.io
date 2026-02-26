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

# MOTD
rm -f /etc/update-motd.d/*
install -D -m 0755 -o root -g root /tmp/rootfs/etc/update-motd.d/00-nice-motd /etc/update-motd.d/00-nice-motd
install -D -m 0644 -o root -g root /tmp/rootfs/etc/motd /etc/motd

# modprobe
install -D -m 0644 -o root -g root /tmp/rootfs/etc/modprobe.d/nvidia-perf.conf /etc/modprobe.d/nvidia-perf.conf

# systemd overrides
install -D -m 0644 -o root -g root /tmp/rootfs/etc/systemd/system/docker.socket.d/override.conf /etc/systemd/system/docker.socket.d/override.conf
install -D -m 0644 -o root -g root /tmp/rootfs/etc/systemd/system/mount-local.service /etc/systemd/system/mount-local.service
install -D -m 0644 -o root -g root /tmp/rootfs/etc/systemd/system/otelcol-contrib.service.d/override.conf /etc/systemd/system/otelcol-contrib.service.d/override.conf

# sudoers (must be 0440)
install -D -m 0440 -o root -g root /tmp/rootfs/etc/sudoers.d/audit /etc/sudoers.d/audit

# docker
install -D -m 0644 -o root -g root /tmp/rootfs/etc/docker/daemon.json /etc/docker/daemon.json

# audit
install -D -m 0640 -o root -g adm /tmp/rootfs/etc/audit/rules.d/zjusct.rules /etc/audit/rules.d/zjusct.rules

# udev
install -D -m 0644 -o root -g root /tmp/rootfs/etc/udev/hwdb.d/50-net-naming-denylist.hwdb /etc/udev/hwdb.d/50-net-naming-denylist.hwdb

# mirrors
install -D -m 0644 -o root -g root /tmp/rootfs/etc/uv/uv.toml /etc/uv/uv.toml
install -D -m 0644 -o root -g root /tmp/rootfs/opt/conda/.condarc /opt/conda/.condarc

# otelcol-contrib
install -D -m 0640 -o root -g root /tmp/rootfs/etc/otelcol-contrib/config.yaml /etc/otelcol-contrib/config.yaml

# mount local disks
install -D -m 0755 -o root -g root /tmp/rootfs/usr/local/bin/mount-local.sh /usr/local/bin/mount-local.sh
systemctl enable mount-local

########################################################################
# NFS over RDMA
########################################################################
sed -E -i 's/^#[[:space:]]*rdma=n$/rdma=y/' "/etc/nfs.conf"

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
# GRUB - Set default kernel
########################################################################

# Method: GRUB_DEFAULT="saved" + grub-set-default
# - GRUB_DEFAULT="saved" tells GRUB to use the value saved in grubenv
# - grub-set-default writes the selected entry to /boot/grub/grubenv
# This approach is more reliable than using menu index (1>2) because:
#   - It survives kernel updates that change menu order
#   - It uses the exact menu entry title as identifier

sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT="saved"/' /etc/default/grub
update-grub
grub-set-default "Advanced options for Debian GNU/Linux>Debian GNU/Linux, with Linux 6.12.41+deb13-amd64"
