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
MIIDEDCCAfigAwIBAgIUFaKLwf8vosV0cVNz3ZYOCfGczzMwDQYJKoZIhvcNAQEL
BQAwIDEeMBwGA1UEAxMVWkpVU0NUIFNxdWlkIFByb3h5IENBMB4XDTI2MDUwNTEz
NTIxOVoXDTI4MDUwNDEzNTIxOVowIDEeMBwGA1UEAxMVWkpVU0NUIFNxdWlkIFBy
b3h5IENBMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAxV2fl/4rZCm6
3YQfPIpS/rsca/XTxoH5b4J3tGSTY5MffS5a22aZNlU6fef0WIM3QT0LggQWXPfW
c9WVtiiblFdhUSzT0eBHNCy8wMkcztBHlZN/mRLiws0atUGXg5cGO8+MvTf0BEIT
EEVEa6eZVz7FcUikGmYhQIwzX1k0hmszSCM7tzgxxUZrtb+NjiVo/4DOl8YHQ0bv
w/lAxXvIHvimY/NQTxjszm2lUULKkYE5tu+rpCQ+/zkgwuoFu8zr2I2lSImka4WB
XSuH3WphKLt8tJns3LR5m2zygB+rE5CmGLb60+GJhUexoCFt3JmvOYVSubqfYbX1
g2Z+czBBLQIDAQABo0IwQDAOBgNVHQ8BAf8EBAMCAqQwDwYDVR0TAQH/BAUwAwEB
/zAdBgNVHQ4EFgQUKBcULSAUTp4dL83Y6+wLYSXSBh4wDQYJKoZIhvcNAQELBQAD
ggEBAD4ymTXJhw1PG7AYfGr5v9OFOdrt3XY5akv+W4lS4anJwT8K3MzSp3MIJplP
CDjls2E5+D8yklXlA6y0ecGnijgP3W5iALraADcoy0oF1Sms0eDWfjRAn8LeG9fU
7b3Q75yWx7F5PZ9TvFEVxZxSMQsLvV5P7xw4N/W8y/AUXui3w3kbD8hZFGHMwksf
pUlrN+9TnEOHforisIL24fNXgDKPRB25mPShcPi6aBA8psS5yFyn2UEGfMqvBoDh
L8FewOSdjOowXLtzFz1FBx80DpI+zRXRqd14bI9iGu/DxqtNgo+1lifpBa9Sd/hx
zUbS2cVvyfHKpYRKnPBeBPXAWoc=
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
