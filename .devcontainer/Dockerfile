# https://mcr.microsoft.com/en-us/artifact/mar/devcontainers/base/about
ARG DEBIAN_VERSION=trixie
FROM harbor.clusters.zjusct.io/mcr.microsoft.com/devcontainers/base:${DEBIAN_VERSION}

COPY squid.crt /usr/local/share/ca-certificates/squid.crt
RUN update-ca-certificates

ARG MIRROR=mirrors.zju.edu.cn
ARG K8S_VERSION=v1.35
ARG KUBESEAL_VERSION=0.36.1
ARG HTTP_PROXY=http://172.28.0.4:3128
ARG HTTPS_PROXY=http://172.28.0.4:3128

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

# <<< K8S APT Repo
curl -fsSL https://mirrors.cernet.edu.cn/kubernetes/core:/stable:/${K8S_VERSION}/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg
cat <<EOT | tee /etc/apt/sources.list.d/kubernetes.list
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://mirrors.cernet.edu.cn/kubernetes/core:/stable:/${K8S_VERSION}/deb/ /
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
    npm \
    packer \
    kubectl \
    helm \
    python3-yaml \
    python3-dotenv \
    python3-pip \
    python3 \
    tmux \
    vim \
    btop \
    pre-commit \
    qemu-system-x86 \
    qemu-utils \
    ovmf \
    cloud-init \
    cloud-image-utils
apt-get autoremove -y

# Packer expects OVMF_CODE.fd / OVMF_VARS.fd, Debian ships OVMF_CODE_4M.fd / OVMF_VARS_4M.fd
ln -sf /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd
ln -sf /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd
EOF

RUN <<EOF
set -xe
# https://argo-cd.readthedocs.io/en/stable/cli_installation/
curl -sSL "https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64" -o /usr/local/bin/argocd
chmod +x /usr/local/bin/argocd

# https://kubectl.docs.kubernetes.io/installation/kustomize/binaries/
cd /usr/local/bin
curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash

# https://github.com/minio/mc
wget -q https://dl.min.io/client/mc/release/linux-amd64/mc
chmod +x mc

# https://github.com/bitnami-labs/sealed-secrets
curl -sSL "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz" | tar xz -C /usr/local/bin/
chmod +x /usr/local/bin/kubeseal

npm config --global set registry https://registry.npmmirror.com
npm install -g \
    opencode-ai \
    @anthropic-ai/claude-code \
    @openai/codex \
    @google/gemini-cli

pip config --global set global.index-url https://${MIRROR}/pypi/web/simple
EOF

COPY post-start.sh /usr/local/share/devcontainer/post-start.sh
RUN chmod a+rx /usr/local/share/devcontainer/post-start.sh

RUN apt-get distclean -y
