FROM harbor.clusters.zjusct.io/docker.io/library/debian:stable-slim

ENV DEBIAN_FRONTEND=noninteractive
ARG HTTP_PROXY=http://172.28.0.4:3128
ARG HTTPS_PROXY=http://172.28.0.4:3128

COPY squid.crt /usr/local/share/ca-certificates/squid.crt

RUN <<EOF
set -xe
. /etc/os-release

find /etc/apt -type f \( -name '*.list' -o -name '*.sources' \) \
    -exec sed -i -e 's/[a-z]*\.debian\.org/mirrors.cernet.edu.cn/g' {} +
cat <<EOT > /etc/apt/sources.list.d/debian.sources
Types: deb
URIs: http://mirrors.cernet.edu.cn/debian/
Suites: ${VERSION_CODENAME} ${VERSION_CODENAME}-updates
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOT

apt-get update
apt-get install -y --no-install-recommends ca-certificates gpg curl

update-ca-certificates

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

packer plugins install github.com/hashicorp/qemu
EOF

ENTRYPOINT ["bash"]
