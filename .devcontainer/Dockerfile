FROM harbor.clusters.zjusct.io/mcr.microsoft.com/devcontainers/base:ubuntu

ARG MIRROR=mirrors.aliyun.com
ENV MIRROR=${MIRROR}

RUN sed -i "s|http://archive.ubuntu.com|https://${MIRROR}|g" /etc/apt/sources.list.d/*.sources 2>/dev/null || true
RUN sed -i "s|http://security.ubuntu.com|https://${MIRROR}|g" /etc/apt/sources.list.d/*.sources 2>/dev/null || true

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    wget \
    jq \
    git \
    npm \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*

RUN curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" \
    && install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl \
    && rm kubectl

RUN curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4 \
    && chmod 700 get_helm.sh \
    && ./get_helm.sh \
    && rm get_helm.sh

RUN curl -sSL "https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64" -o /usr/local/bin/argocd \
    && chmod +x /usr/local/bin/argocd

RUN curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash

RUN KUBESEAL_VERSION=$(curl -s https://api.github.com/repos/bitnami-labs/sealed-secrets/releases/latest | jq -r '.tag_name' | sed 's/^v//') \
    && curl -sSL "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz" | tar xz -C /usr/local/bin/ \
    && chmod +x /usr/local/bin/kubeseal

RUN npm config --global set registry https://registry.npmmirror.com \
    && npm install -g opencode-ai

RUN pip config --global \
    set global.index-url https://mirrors.zju.edu.cn/pypi/web/simple \
    && pip install --break-system-packages pre-commit 
