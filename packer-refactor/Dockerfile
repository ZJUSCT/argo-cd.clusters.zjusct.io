FROM harbor.clusters.zjusct.io/docker.io/library/debian:stable-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN <<EOF
set -xe
. /etc/os-release

apt-get update
apt-get install -y --no-install-recommends ca-certificates gpg curl

cat <<EOT > /etc/apt/sources.list.d/debian.sources
Types: deb
URIs: https://mirrors.zju.edu.cn/debian/
Suites: ${VERSION_CODENAME} ${VERSION_CODENAME}-updates
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOT

curl -fsSL https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
chmod 644 /usr/share/keyrings/hashicorp-archive-keyring.gpg
cat <<EOT | tee /etc/apt/sources.list.d/hashicorp.list
deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com ${VERSION_CODENAME} main
EOT

apt-get update
apt-get install -y --no-install-recommends \
    qemu-system-x86 \
    qemu-system-arm \
    qemu-system-riscv \
    qemu-utils \
    ovmf \
    qemu-efi-aarch64 \
    qemu-efi-riscv64 \
    cloud-init \
    cloud-image-utils \
    make \
    bash \
    openssh-client \
    packer \
    python3 \
    python3-yaml
apt-get autoremove -y
apt-get distclean
EOF

RUN <<EOF
set -xe
packer plugins install github.com/hashicorp/qemu
EOF

ENTRYPOINT ["bash"]
