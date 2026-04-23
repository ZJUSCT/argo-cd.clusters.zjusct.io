#!/usr/bin/env bash
# shellcheck disable=SC1091
source /tmp/00-shared.sh

########################################################################
# K8S packages (kubectl, kubeadm, kubelet)
# https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/
########################################################################

case $ID in
ubuntu | debian)
    add_repo "kubernetes" \
        "https://mirrors.cernet.edu.cn/kubernetes/core:/stable:/v1.32/deb/Release.key" \
        "deb [signed-by=/etc/apt/keyrings/kubernetes.gpg] https://mirrors.cernet.edu.cn/kubernetes/core:/stable:/v1.32/deb/ /"
    install_pkg kubectl kubeadm kubelet
    ;;
fedora)
    cat >/etc/yum.repos.d/kubernetes.repo <<EOF
[kubernetes]
name=Kubernetes
baseurl=https://mirrors.cernet.edu.cn/kubernetes/core:/stable:/v1.32/rpm/
enabled=1
gpgcheck=1
gpgkey=https://mirrors.cernet.edu.cn/kubernetes/core:/stable:/v1.32/rpm/repodata/repomd.xml.key
EOF
    install_pkg kubectl kubeadm kubelet
    ;;
arch)
    install_pkg kubectl kubeadm kubelet
    ;;
*)
    echo "K8S packages: unsupported distro $ID, skipping"
    ;;
esac

systemctl disable --now kubelet

########################################################################
# Helm
# https://helm.sh/docs/intro/install/
########################################################################

case $ID in
ubuntu | debian)
    add_repo "helm" \
        "https://packages.buildkite.com/helm-linux/helm-debian/gpgkey" \
        "deb [signed-by=/etc/apt/keyrings/helm.gpg] https://packages.buildkite.com/helm-linux/helm-debian/any/ any main"
    ;;
fedora)
    dnf install -y helm
    ;;
arch)
    install_pkg helm
    ;;
*)
    echo "Helm: unsupported distro $ID, skipping"
    ;;
esac

########################################################################
# Argo CD CLI
# https://argo-cd.readthedocs.io/en/stable/cli_installation/
# Supports: amd64, arm64
########################################################################

case "$ARCH" in
x86_64 | amd64)
    install_bin_from_github "argoproj/argo-cd" "argocd-linux-amd64" "argocd"
    ;;
aarch64 | arm64)
    install_bin_from_github "argoproj/argo-cd" "argocd-linux-arm64" "argocd"
    ;;
*)
    echo "Argo CD: unsupported arch $ARCH, skipping"
    ;;
esac

########################################################################
# Cilium CLI + Hubble
# https://docs.cilium.io/en/stable/gettingstarted/k8s-install-helm/
# Supports: amd64, arm64
########################################################################

case "$ARCH" in
x86_64 | amd64)
    cilium_arch="amd64"
    ;;
aarch64 | arm64)
    cilium_arch="arm64"
    ;;
*)
    echo "Cilium/Hubble: unsupported arch $ARCH, skipping"
    cilium_arch=""
    ;;
esac

if [ -n "${cilium_arch:-}" ]; then
    install_tarball_from_github "cilium/cilium-cli" "cilium-linux-${cilium_arch}.tar.gz"
    install_tarball_from_github "cilium/hubble" "hubble-linux-${cilium_arch}.tar.gz"
fi

########################################################################
# Kubeseal (Sealed Secrets)
# https://github.com/bitnami-labs/sealed-secrets
# Supports: amd64, arm64
########################################################################

case "$ARCH" in
x86_64 | amd64)
    install_tarball_from_github "bitnami-labs/sealed-secrets" "kubeseal-*-linux-amd64.tar.gz"
    ;;
aarch64 | arm64)
    install_tarball_from_github "bitnami-labs/sealed-secrets" "kubeseal-*-linux-arm64.tar.gz"
    ;;
*)
    echo "Kubeseal: unsupported arch $ARCH, skipping"
    ;;
esac

########################################################################
# Kustomize
# https://kubectl.docs.kubernetes.io/references/kustomize/kustomize/
# Supports: amd64, arm64
########################################################################

case "$ARCH" in
x86_64 | amd64)
    install_tarball_from_github "kubernetes-sigs/kustomize" "kustomize_*_linux_amd64.tar.gz"
    ;;
aarch64 | arm64)
    install_tarball_from_github "kubernetes-sigs/kustomize" "kustomize_*_linux_arm64.tar.gz"
    ;;
*)
    echo "Kustomize: unsupported arch $ARCH, skipping"
    ;;
esac

########################################################################
# Virtctl (KubeVirt)
# https://kubevirt.io/
# Supports: amd64, arm64
########################################################################

case "$ARCH" in
x86_64 | amd64)
    install_bin_from_github "kubevirt/kubevirt" "virtctl-v*-linux-amd64" "virtctl"
    ;;
aarch64 | arm64)
    install_bin_from_github "kubevirt/kubevirt" "virtctl-v*-linux-arm64" "virtctl"
    ;;
*)
    echo "Virtctl: unsupported arch $ARCH, skipping"
    ;;
esac

########################################################################
# Packer
# https://developer.hashicorp.com/packer
########################################################################

case $ID in
ubuntu | debian)
    add_repo "hashicorp" \
        "https://apt.releases.hashicorp.com/gpg" \
        "deb [signed-by=/etc/apt/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com $VERSION_CODENAME main"
    install_pkg packer
    ;;
fedora)
    dnf install -y dnf-plugins-core
    dnf config-manager --add-repo https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo
    install_pkg packer
    ;;
arch)
    install_pkg packer
    ;;
*)
    echo "Packer: unsupported distro $ID, skipping"
    ;;
esac
