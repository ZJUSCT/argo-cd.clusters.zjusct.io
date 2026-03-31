# https://mcr.microsoft.com/en-us/artifact/mar/devcontainers/base/about
ARG DEBIAN_VERSION=trixie
FROM harbor.clusters.zjusct.io/mcr.microsoft.com/devcontainers/base:${DEBIAN_VERSION}

ARG DEBIAN_VERSION=${DEBIAN_VERSION}
ARG MIRROR=mirrors.zju.edu.cn
ARG K8S_VERSION
ARG KUBESEAL_VERSION

RUN <<EOF
cat <<EOT > /etc/apt/sources.list.d/debian.sources
Types: deb
URIs: https://${MIRROR}/debian/
Suites: ${DEBIAN_VERSION} ${DEBIAN_VERSION}-updates ${DEBIAN_VERSION}-backports
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: https://${MIRROR}/debian-security/
Suites: ${DEBIAN_VERSION}-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOT

# <<< K8S APT Repo
curl -fsSL https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
sudo chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg
cat <<EOT | sudo tee /etc/apt/sources.list.d/kubernetes.list
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/ /
EOT
sudo chmod 644 /etc/apt/sources.list.d/kubernetes.list
# >>>

# <<< HashiCorp APT Repo
curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
cat <<EOT | sudo tee /etc/apt/sources.list.d/hashicorp.list
deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com ${DEBIAN_VERSION} main
EOT
# >>>

# <<< HELM APT Repo
curl -fsSL https://packages.buildkite.com/helm-linux/helm-debian/gpgkey | gpg --dearmor | sudo tee /usr/share/keyrings/helm.gpg > /dev/null
cat <<EOT | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list
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
    python3-pip \
    python3-full
EOF

RUN <<EOF
curl -sSL "https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64" -o /usr/local/bin/argocd
chmod +x /usr/local/bin/argocd

curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash

curl -sSL "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz" | tar xz -C /usr/local/bin/
chmod +x /usr/local/bin/kubeseal

npm config --global set registry https://registry.npmmirror.com
npm install -g \
    opencode-ai \
    @anthropic-ai/claude-code \
    @openai/codex \
    @google/gemini-cli

pip config --global set global.index-url https://${MIRROR}/pypi/web/simple
pip install --break-system-packages pre-commit
EOF
