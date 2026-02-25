#!/bin/bash
# Mount ext4 disks to /local/nvme-N or /local/sata-N
set -e
shopt -s nullglob

mkdir -p /local

# Counter for SATA and NVMe disks
sata_count=0
nvme_count=0

# Check all SATA disks (/dev/sda, /dev/sdb, etc.)
for disk in /dev/sd[a-z] /dev/sd[a-z][a-z]; do
    if [ -b "$disk" ] && blkid "$disk" | grep -q ext4; then
        mount_point="/local/sata-$sata_count"
        mkdir -p "$mount_point"
        mount "$disk" "$mount_point"
        chmod 777 "$mount_point"
        ((sata_count++))
    fi
done

# Check all NVMe disks (/dev/nvme*n1)
for disk in /dev/nvme*n1; do
    if [ -b "$disk" ] && blkid "$disk" | grep -q ext4; then
        mount_point="/local/nvme-$nvme_count"
        mkdir -p "$mount_point"
        mount "$disk" "$mount_point"
        chmod 777 "$mount_point"
        ((nvme_count++))
    fi
done
