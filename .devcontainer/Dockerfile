# https://mcr.microsoft.com/en-us/artifact/mar/devcontainers/base/about
# FROM mcr.microsoft.com/devcontainers/base:trixie
FROM harbor.clusters.zjusct.io/mcr.microsoft.com/devcontainers/base:trixie

ARG HTTP_PROXY=http://172.28.0.4:3128
ARG HTTPS_PROXY=http://172.28.0.4:3128
ARG NO_PROXY=localhost,zjusct.io

ENV MIRROR=mirrors.cernet.edu.cn
ARG K8S_VERSION=v1.35
ENV DEBIAN_FRONTEND=noninteractive

RUN <<EOF
set -xe
. /etc/os-release

cat <<EOT > /usr/local/share/ca-certificates/squid.crt
-----BEGIN CERTIFICATE-----
MIIDEDCCAfigAwIBAgIUNXZxL6wleVbCUKejb+FHKRPwU6QwDQYJKoZIhvcNAQEL
BQAwIDEeMBwGA1UEAxMVWkpVU0NUIFNxdWlkIFByb3h5IENBMB4XDTI2MDIxODEz
NDIyNloXDTI2MDUxOTEzNDIyNlowIDEeMBwGA1UEAxMVWkpVU0NUIFNxdWlkIFBy
b3h5IENBMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAs4GfDEih4myZ
ykMQOAY/AdM2W9xo5Q4luK8/bLOxa2CYi4BxRrhA7EBvHMhJpBF7FAbWdn/Kzt79
yAMkNUGvG32f3R/gdQC4rJoWKFAdOEwj7TmIHLK6smwQ8uXA2qJNAD8FstR7XmMD
qMlbkp2XOV7rbIF+YeDiAQ+00fM9TBDC4X2acYtGyxtI+9k93bXTNXMkThK8NFxm
k0KmsYnFMEmFQ9TIbiUvDNr+j/Tqj7Hw1CJz+4pod38cZPeXY71U+pBTg9lWpEi3
97aIIvPB0vvdoVI82v6kFaoPVOrXcpeZdJ22Spu/vxECcBUeJVRmVMmXWUepbOJp
8U/mEvbnkwIDAQABo0IwQDAOBgNVHQ8BAf8EBAMCAqQwDwYDVR0TAQH/BAUwAwEB
/zAdBgNVHQ4EFgQUCMQoUV5+UuHWCSmuX0bA+AndP6owDQYJKoZIhvcNAQELBQAD
ggEBAFgqj89+jbaf0+u+KJDphkTiJSAc1dm4O2G09bbNHxpp5oRr3NT/WWxgyifL
9indbnByyXd2ywT5LRXTRhF+RMu6Xf4PO/2sI9k73RVrT3mvdcn96apJXrUb3omp
vMpisbakaaREY6GJPfln273uJcQGOyg57kaG2ASMucuJlo70w9JQUx/icF5gjxFl
L6FXhdYs5L6KZorYdQLw3OPdmS5Vu22EMlW6GPhFCIXZIHPLdcFEF3toqTKlHRiJ
wl/J5hxlSQWIDUZZi28Dm/NkV650nN3MsdAJP33mRwGkFeZSdv3w2Lgnajewj/4m
XljL5sQrprvcir5cDWXSAgno1NA=
-----END CERTIFICATE-----

EOT
update-ca-certificates

cat <<EOT > /etc/apt/sources.list.d/debian.sources
Types: deb
URIs: https://${MIRROR}/debian/
Suites: ${VERSION_CODENAME} ${VERSION_CODENAME}-updates ${VERSION_CODENAME}-backports
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: https://${MIRROR}/debian-security/
Suites: ${VERSION_CODENAME}-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOT

# <<< K8S APT Repo
curl -fsSL https://${MIRROR}/kubernetes/core:/stable:/${K8S_VERSION}/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg
cat <<EOT | tee /etc/apt/sources.list.d/kubernetes.list
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://${MIRROR}/kubernetes/core:/stable:/${K8S_VERSION}/deb/ /
EOT
chmod 644 /etc/apt/sources.list.d/kubernetes.list
# >>>

# <<< HashiCorp APT Repo
curl -fsSL https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
chmod 644 /usr/share/keyrings/hashicorp-archive-keyring.gpg
cat <<EOT | tee /etc/apt/sources.list.d/hashicorp.list
deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com ${VERSION_CODENAME} main
EOT
# >>>

# <<< HELM APT Repo
curl -fsSL https://packages.buildkite.com/helm-linux/helm-debian/gpgkey | gpg --dearmor | tee /usr/share/keyrings/helm.gpg > /dev/null
chmod 644 /usr/share/keyrings/helm.gpg
cat <<EOT | tee /etc/apt/sources.list.d/helm-stable-debian.list
deb [signed-by=/usr/share/keyrings/helm.gpg] https://packages.buildkite.com/helm-linux/helm-debian/any/ any main
EOT
# >>>

apt-get update
apt-get install -y --no-install-recommends \
    curl \
    wget \
    jq \
    git \
    packer \
    kubectl \
    helm \
    fish \
    python3-yaml \
    python3-dotenv \
    python3-pip \
    python3 \
    tmux \
    vim \
    btop \
    pre-commit \
    qemu-system-x86 \
    ovmf \
    qemu-system-arm \
    qemu-efi-aarch64 \
    qemu-system-riscv \
    qemu-efi-riscv64 \
    qemu-utils \
    cloud-init \
    cloud-image-utils \
    minio-client
apt-get autoremove -y
apt-get distclean
EOF

RUN <<EOF
set -xe
. /etc/os-release

# https://argo-cd.readthedocs.io/en/stable/cli_installation/
curl -sSL "https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64" -o /usr/local/bin/argocd
chmod +x /usr/local/bin/argocd

# https://kubectl.docs.kubernetes.io/installation/kustomize/binaries/
cd /usr/local/bin
curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash

# https://github.com/bitnami-labs/sealed-secrets
KUBESEAL_VERSION=$(curl -fsSL https://api.github.com/repos/bitnami-labs/sealed-secrets/releases/latest | jq -r .tag_name | sed 's/^v//')
curl -sSL "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz" | tar xz -C /usr/local/bin/
chmod +x /usr/local/bin/kubeseal

# https://github.com/zellij-org/zellij
curl -sSL "https://github.com/zellij-org/zellij/releases/latest/download/zellij-x86_64-unknown-linux-musl.tar.gz" | tar xz -C /usr/local/bin/
chmod +x /usr/local/bin/zellij

# https://claude.ai/install.sh
version=$(curl -fsSL https://downloads.claude.ai/claude-code-releases/latest)
curl -fsSL -o /usr/local/bin/claude "https://downloads.claude.ai/claude-code-releases/${version}/linux-x64/claude"
chmod 755 /usr/local/bin/claude

# https://docs.astral.sh/uv/getting-started/installation/
curl -sSL "https://github.com/astral-sh/uv/releases/latest/download/uv-x86_64-unknown-linux-musl.tar.gz" | tar xz --strip-components=1 -C /usr/local/bin/ uv-x86_64-unknown-linux-musl/uv uv-x86_64-unknown-linux-musl/uvx

install -D -m 0644 /dev/stdin /etc/uv/uv.toml <<EOT
[[index]]
url = "https://${MIRROR}/pypi/web/simple/"
default = true
EOT

pip config --global set global.index-url https://${MIRROR}/pypi/web/simple

EOF
