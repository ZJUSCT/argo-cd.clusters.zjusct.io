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

# modprobe
install -D -m 0644 -o root -g root /tmp/rootfs/etc/modprobe.d/nvidia-perf.conf /etc/modprobe.d/nvidia-perf.conf

# systemd overrides
install -D -m 0644 -o root -g root /tmp/rootfs/etc/systemd/resolved.conf.d/disable-llmnr.conf /etc/systemd/resolved.conf.d/disable-llmnr.conf

# udev
install -D -m 0644 -o root -g root /tmp/rootfs/etc/udev/hwdb.d/50-net-naming-denylist.hwdb /etc/udev/hwdb.d/50-net-naming-denylist.hwdb

# netplan
install -D -m 0600 -o root -g root /tmp/rootfs/etc/netplan/99-zjusct-network-manager.yaml /etc/netplan/99-zjusct-network-manager.yaml

# mirrors
install -D -m 0644 -o root -g root /tmp/rootfs/etc/uv/uv.toml /etc/uv/uv.toml
install -D -m 0644 -o root -g root /tmp/rootfs/opt/conda/.condarc /opt/conda/.condarc

########################################################################
# NFS over RDMA
########################################################################
sed -E -i 's/^#[[:space:]]*rdma=n$/rdma=y/' "/etc/nfs.conf"
