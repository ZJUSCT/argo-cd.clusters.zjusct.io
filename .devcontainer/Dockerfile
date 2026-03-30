# https://mcr.microsoft.com/en-us/artifact/mar/devcontainers/base/about
ARG DEBIAN_VERSION=trixie
FROM harbor.clusters.zjusct.io/mcr.microsoft.com/devcontainers/base:${DEBIAN_VERSION}

ARG DEBIAN_VERSION=${DEBIAN_VERSION}
ENV DEBIAN_VERSION=${DEBIAN_VERSION}
ARG MIRROR=mirrors.zju.edu.cn
ENV MIRROR=${MIRROR}

RUN <<EOF
cat <<EOT > /etc/apt/sources.list.d/debian.sources
Types: deb
URIs: https://mirrors.zju.edu.cn/debian/
Suites: ${DEBIAN_VERSION} ${DEBIAN_VERSION}-updates ${DEBIAN_VERSION}-backports
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: https://mirrors.zju.edu.cn/debian-security/
Suites: ${DEBIAN_VERSION}-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOT

# <<< K8S APT Repo
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.35/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
sudo chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.35/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo chmod 644 /etc/apt/sources.list.d/kubernetes.list
# >>>

apt-get update
apt-get install -y --no-install-recommends \
    curl \
    wget \
    jq \
    git \
    npm \
    packer \
    python3-pip \
    python3-full
EOF

# RUN <<EOF
# curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
# install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl \
# rm kubectl
# EOF
#
# RUN curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4 \
#     && chmod 700 get_helm.sh \
#     && ./get_helm.sh \
#     && rm get_helm.sh
#
# RUN curl -sSL "https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64" -o /usr/local/bin/argocd \
#     && chmod +x /usr/local/bin/argocd
#
# RUN curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash
#
# RUN KUBESEAL_VERSION=$(curl -s https://api.github.com/repos/bitnami-labs/sealed-secrets/releases/latest | jq -r '.tag_name' | sed 's/^v//') \
#     && curl -sSL "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz" | tar xz -C /usr/local/bin/ \
#     && chmod +x /usr/local/bin/kubeseal
#
# RUN npm config --global set registry https://registry.npmmirror.com \
#     && npm install -g opencode-ai
#
# RUN pip config --global \
#     set global.index-url https://mirrors.zju.edu.cn/pypi/web/simple \
#     && pip install --break-system-packages pre-commit
