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

    [ -b "$disk" ] || continue

    # Get the filesyste type of the disk
    fstype=$(blkid -o value -s TYPE "$disk" 2>/dev/null || true)

    # Format the disk as ext4 if it doesn't have a filesystem
    if [ -z "$fstype" ] && command -v blkid >/dev/null 2>&1; then
        echo "Formatting $disk as ext4"
        mkfs.ext4 -F "$disk"
        fstype="ext4"
    fi

    if [ -b "$disk" ] && blkid "$disk" | grep -q ext4; then
        mount_point="/local/sata-$sata_count"
        mkdir -p "$mount_point"
        mount "$disk" "$mount_point"

        #Set ACL for zjusct group
        chgrp zjusct "$mount_point"
        chmod 2770 "$mount_point"
        setfacl -m g:zjusct:rwx "$mount_point"         # 当前权限
        setfacl -d -m g:zjusct:rwx "$mount_point"      # 默认 ACL

        ((sata_count++))
    fi
done

# Check all NVMe disks (/dev/nvme*n1)
for disk in /dev/nvme*n1; do

    [ -b "$disk" ] || continue

    # Get the filesyste type of the disk
    fstype=$(blkid -o value -s TYPE "$disk" 2>/dev/null || true)

    # Format the disk as ext4 if it doesn't have a filesystem
    if [ -z "$fstype" ] && command -v blkid >/dev/null 2>&1; then
        echo "Formatting $disk as ext4"
        mkfs.ext4 -F "$disk"
        fstype="ext4"
    fi

    if [ -b "$disk" ] && blkid "$disk" | grep -q ext4; then
        mount_point="/local/nvme-$nvme_count"
        mkdir -p "$mount_point"
        mount "$disk" "$mount_point"

        #Set ACL for zjusct group
        chgrp zjusct "$mount_point"
        chmod 2770 "$mount_point"
        setfacl -m g:zjusct:rwx "$mount_point"         # 当前权限
        setfacl -d -m g:zjusct:rwx "$mount_point"      # 默认 ACL

        ((nvme_count++))
    fi
done
