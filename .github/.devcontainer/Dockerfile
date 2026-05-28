# https://mcr.microsoft.com/en-us/artifact/mar/devcontainers/base/about
FROM mcr.microsoft.com/devcontainers/base:trixie

ARG TARGETARCH
ENV DEBIAN_FRONTEND=noninteractive

RUN <<EOF
set -xe
. /etc/os-release

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
    kustomize \
    fish \
    python3-yaml \
    python3-dotenv \
    python3-pip \
    python3-jinja2 \
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
    minio-client \
    unzip \
    shellcheck \
    shfmt
apt-get autoremove -y
apt-get distclean
EOF

# https://argo-cd.readthedocs.io/en/stable/cli_installation/
RUN <<EOF
set -xe
ARCH=${TARGETARCH:-$(dpkg --print-architecture)}
curl -fsSL -o /usr/local/bin/argocd "https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-${ARCH}"
chmod +x /usr/local/bin/argocd
EOF

# https://github.com/bitnami-labs/sealed-secrets
RUN <<EOF
set -xe
ARCH=${TARGETARCH:-$(dpkg --print-architecture)}
KUBESEAL_VERSION=$(curl -fsSL https://api.github.com/repos/bitnami-labs/sealed-secrets/releases/latest | jq -r .tag_name | sed 's/^v//')
curl -fsSL "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-${ARCH}.tar.gz" | tar xz -C /usr/local/bin/
chmod +x /usr/local/bin/kubeseal
EOF

# https://github.com/zellij-org/zellij
RUN <<EOF
set -xe
ARCH=${TARGETARCH:-$(dpkg --print-architecture)}
case "${ARCH}" in
  amd64) RUST_TARGET="x86_64-unknown-linux-musl" ;;
  arm64) RUST_TARGET="aarch64-unknown-linux-musl" ;;
esac
curl -fsSL "https://github.com/zellij-org/zellij/releases/latest/download/zellij-${RUST_TARGET}.tar.gz" | tar xz -C /usr/local/bin/
chmod +x /usr/local/bin/zellij
EOF

# https://kubevirt.io/user-guide/user_workloads/virtctl_client_tool/
RUN <<EOF
set -xe
ARCH=${TARGETARCH:-$(dpkg --print-architecture)}
export VERSION=$(curl https://storage.googleapis.com/kubevirt-prow/release/kubevirt/kubevirt/stable.txt)
curl -fsSL -o /usr/local/bin/virtctl "https://github.com/kubevirt/kubevirt/releases/download/${VERSION}/virtctl-${VERSION}-linux-${ARCH}"
chmod +x /usr/local/bin/virtctl
EOF

# https://code.claude.com/docs/en/quickstart
RUN <<EOF
set -xe
ARCH=${TARGETARCH:-$(dpkg --print-architecture)}
case "${ARCH}" in
  amd64) PLATFORM="linux-x64" ;;
  arm64) PLATFORM="linux-arm64" ;;
esac
version=$(curl -fsSL https://downloads.claude.ai/claude-code-releases/latest)
curl -fsSL -o /usr/local/bin/claude "https://downloads.claude.ai/claude-code-releases/${version}/${PLATFORM}/claude"
chmod 755 /usr/local/bin/claude
EOF

# https://opencode.ai/download
RUN <<EOF
set -xe
ARCH=${TARGETARCH:-$(dpkg --print-architecture)}
case "${ARCH}" in
  amd64) SUFFIX="linux-x64" ;;
  arm64) SUFFIX="linux-arm64" ;;
esac
curl -fsSL "https://github.com/anomalyco/opencode/releases/latest/download/opencode-${SUFFIX}.tar.gz" | tar xz -C /usr/local/bin/
chmod 755 /usr/local/bin/opencode
EOF

# https://developers.openai.com/codex/cli
RUN <<EOF
set -xe
ARCH=${TARGETARCH:-$(dpkg --print-architecture)}
case "${ARCH}" in
  amd64) SUFFIX="x86_64-unknown-linux-musl" ;;
  arm64) SUFFIX="aarch64-unknown-linux-musl" ;;
esac
curl -fsSL "https://github.com/openai/codex/releases/latest/download/codex-${SUFFIX}.tar.gz" | tar xz -C /tmp
mv "/tmp/codex-${SUFFIX}" /usr/local/bin/codex
chmod 755 /usr/local/bin/codex
EOF
