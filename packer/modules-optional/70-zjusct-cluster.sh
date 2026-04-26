#!/usr/bin/env bash
# ZJUSCT cluster specific configuration

# shellcheck disable=SC1091
source /run/header

echo 'prefer_fqdn_over_hostname: true' > /etc/cloud/cloud.cfg.d/99-prefer-fqdn.cfg

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

##########################################################################
# mount local disk
##########################################################################
install -D -m 0644 /dev/stdin /etc/systemd/system/mount-local.service <<EOF
[Unit]
Description=Mount /local
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/mount-local.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl enable mount-local.service

install -D -m 0755 /dev/stdin /usr/local/bin/mount-local.sh <<'EOF'
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

        #Set ACL for zjusct group
        chgrp zjusct "$mount_point"
        chmod 2770 "$mount_point"
        setfacl -m g:zjusct:rwx "$mount_point"         # 当前权限
        setfacl -d -m g:zjusct:rwx "$mount_point"      # 默认 ACL

        sata_count=$((sata_count + 1))
    fi
done

# Check all NVMe disks (/dev/nvme*n1)
for disk in /dev/nvme*n1; do

    if [ -b "$disk" ] && blkid "$disk" | grep -q ext4; then
        mount_point="/local/nvme-$nvme_count"
        mkdir -p "$mount_point"
        mount "$disk" "$mount_point"

        #Set ACL for zjusct group
        chgrp zjusct "$mount_point"
        chmod 2770 "$mount_point"
        setfacl -m g:zjusct:rwx "$mount_point"         # 当前权限
        setfacl -d -m g:zjusct:rwx "$mount_point"      # 默认 ACL

        nvme_count=$((nvme_count + 1))
    fi
done
EOF

##########################################################################
# FreeIPA self-enroll environment
##########################################################################

install -D -m 0644 /dev/stdin /opt/ipa.yaml <<EOF
name: ipa
dependencies:
  - python
  - pip
  - pip:
    - urllib3
    - python-freeipa
EOF

source /etc/profile.d/conda.sh

conda env create -f /opt/ipa.yaml -p /opt/ipa
