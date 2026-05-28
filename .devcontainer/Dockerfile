# https://mcr.microsoft.com/en-us/artifact/mar/devcontainers/base/about
FROM mcr.microsoft.com/devcontainers/base:trixie

ENV MIRROR=mirrors.cernet.edu.cn
ARG K8S_VERSION=v1.35
ARG TARGETARCH
ENV DEBIAN_FRONTEND=noninteractive

RUN <<EOF
set -xe
. /etc/os-release

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

# <<< HashiCorp APT Repo
curl -fsSL https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
chmod 644 /usr/share/keyrings/hashicorp-archive-keyring.gpg
cat <<EOT | tee /etc/apt/sources.list.d/hashicorp.list
deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com ${VERSION_CODENAME} main
EOT
# >>>

apt-get update
apt-get install -y --no-install-recommends \
    curl \
    wget \
    jq \
    git \
    packer \
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

pip config --global set global.index-url https://${MIRROR}/pypi/web/simple
EOF

RUN <<EOF
set -xe
# https://argo-cd.readthedocs.io/en/stable/cli_installation/
ARCH=${TARGETARCH:-$(dpkg --print-architecture)}
curl -sSL "https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-${ARCH}" -o /usr/local/bin/argocd
chmod +x /usr/local/bin/argocd
EOF

RUN <<EOF
set -xe
# https://github.com/bitnami-labs/sealed-secrets
ARCH=${TARGETARCH:-$(dpkg --print-architecture)}
KUBESEAL_VERSION=$(curl -fsSL https://api.github.com/repos/bitnami-labs/sealed-secrets/releases/latest | jq -r .tag_name | sed 's/^v//')
curl -sSL "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-${ARCH}.tar.gz" | tar xz -C /usr/local/bin/
chmod +x /usr/local/bin/kubeseal
EOF

RUN <<EOF
set -xe
# https://github.com/zellij-org/zellij
ARCH=${TARGETARCH:-$(dpkg --print-architecture)}
case "${ARCH}" in
  amd64) RUST_TARGET="x86_64-unknown-linux-musl" ;;
  arm64) RUST_TARGET="aarch64-unknown-linux-musl" ;;
esac
curl -sSL "https://github.com/zellij-org/zellij/releases/latest/download/zellij-${RUST_TARGET}.tar.gz" | tar xz -C /usr/local/bin/
chmod +x /usr/local/bin/zellij
EOF

RUN <<EOF
set -xe
# https://kubevirt.io/user-guide/user_workloads/virtctl_client_tool/
ARCH=${TARGETARCH:-$(dpkg --print-architecture)}
export VERSION=$(curl https://storage.googleapis.com/kubevirt-prow/release/kubevirt/kubevirt/stable.txt)
wget https://github.com/kubevirt/kubevirt/releases/download/${VERSION}/virtctl-${VERSION}-linux-${ARCH} -O /usr/local/bin/virtctl
chmod +x /usr/local/bin/virtctl
EOF

RUN <<EOF
set -xe
# https://code.claude.com/docs/en/quickstart
ARCH=${TARGETARCH:-$(dpkg --print-architecture)}
case "${ARCH}" in
  amd64) PLATFORM="linux-x64" ;;
  arm64) PLATFORM="linux-arm64" ;;
esac
version=$(curl -fsSL https://downloads.claude.ai/claude-code-releases/latest)
curl -fsSL -o /usr/local/bin/claude "https://downloads.claude.ai/claude-code-releases/${version}/${PLATFORM}/claude"
chmod 755 /usr/local/bin/claude
EOF

RUN <<EOF
set -xe
# https://opencode.ai/download
ARCH=${TARGETARCH:-$(dpkg --print-architecture)}
case "${ARCH}" in
  amd64) SUFFIX="linux-x64" ;;
  arm64) SUFFIX="linux-arm64" ;;
esac
curl -fsSL "https://github.com/anomalyco/opencode/releases/latest/download/opencode-${SUFFIX}.tar.gz" | tar xz -C /usr/local/bin/
chmod 755 /usr/local/bin/opencode
EOF

RUN <<EOF
set -xe
# https://developers.openai.com/codex/cli
ARCH=${TARGETARCH:-$(dpkg --print-architecture)}
case "${ARCH}" in
  amd64) SUFFIX="x86_64-unknown-linux-musl" ;;
  arm64) SUFFIX="aarch64-unknown-linux-musl" ;;
esac
curl -fsSL "https://github.com/openai/codex/releases/latest/download/codex-${SUFFIX}.tar.gz" | tar xz -C /tmp
mv "/tmp/codex-${SUFFIX}" /usr/local/bin/codex
chmod 755 /usr/local/bin/codex
EOF
