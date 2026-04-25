#!/usr/bin/env bash
# K8S and tools

# shellcheck disable=SC1091
source /tmp/00-shared.sh

########################################################################
# K8S packages (kubectl, kubeadm, kubelet)
# https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/
########################################################################

K8S_VERSION="v1.35"

case $ID in
ubuntu | debian)
    add_repo "kubernetes" \
        "https://${MIRROR}/kubernetes/core:/stable:/$K8S_VERSION/deb/Release.key" \
        "https://${MIRROR}/kubernetes/core:/stable:/$K8S_VERSION/deb/ /"
    install_pkg kubectl kubeadm kubelet
    ;;
fedora | rocky)
    cat >/etc/yum.repos.d/kubernetes.repo <<EOF
[kubernetes]
name=Kubernetes
baseurl=https://${MIRROR}/kubernetes/core:/stable:/$K8S_VERSION/rpm/
enabled=1
gpgcheck=1
gpgkey=https://${MIRROR}/kubernetes/core:/stable:/$K8S_VERSION/rpm/repodata/repomd.xml.key
EOF
    install_pkg kubectl kubeadm kubelet
    ;;
arch)
    install_pkg kubectl kubeadm kubelet
    ;;
*)
    echo "K8S packages: unsupported distro $ID"
    exit 1
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
        "https://packages.buildkite.com/helm-linux/helm-debian/any/ any main"
    install_pkg helm
    ;;
fedora | rocky)
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
x86_64) argocd_arch="amd64" ;;
aarch64 | arm64) argocd_arch="arm64" ;;
*)
    echo "Argo CD: unsupported arch $ARCH, skipping"
    ;;
esac

if [ -n "${argocd_arch:-}" ]; then
    bin=$(get_github_release_asset "argoproj/argo-cd" "argocd-linux-${argocd_arch}$")
    install -m 755 "$bin" /usr/local/bin/argocd
    rm -f "$bin"
fi

########################################################################
# Cilium CLI + Hubble
# https://docs.cilium.io/en/stable/gettingstarted/k8s-install-helm/
# Supports: amd64, arm64
########################################################################

case "$ARCH" in
x86_64)
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
    tarball=$(get_github_release_asset "cilium/cilium-cli" "^cilium-linux-${cilium_arch}\\.tar\\.gz$")
    tar xzf "$tarball" -C /usr/local/bin/ cilium
    rm -f "$tarball"

    tarball=$(get_github_release_asset "cilium/hubble" "^hubble-linux-${cilium_arch}\\.tar\\.gz$")
    tar xzf "$tarball" -C /usr/local/bin/ hubble
    rm -f "$tarball"
fi

########################################################################
# Kubeseal (Sealed Secrets)
# https://github.com/bitnami-labs/sealed-secrets
########################################################################

case "$ARCH" in
x86_64) kubeseal_arch="amd64" ;;
aarch64 | arm64) kubeseal_arch="arm64" ;;
*)
    echo "Kubeseal: unsupported arch $ARCH, skipping"
    kubeseal_arch=""
    ;;
esac

if [ -n "${kubeseal_arch:-}" ]; then
    tarball=$(get_github_release_asset "bitnami-labs/sealed-secrets" "^kubeseal-[0-9]+\\.[0-9]+\\.[0-9]+-linux-${kubeseal_arch}\\.tar\\.gz$")
    tar xzf "$tarball" -C /usr/local/bin/ kubeseal
    rm -f "$tarball"
fi

########################################################################
# Kustomize
# https://kubectl.docs.kubernetes.io/references/kustomize/kustomize/
# Supports: amd64, arm64
########################################################################

case "$ARCH" in
x86_64) kustomize_arch="amd64" ;;
aarch64 | arm64) kustomize_arch="arm64" ;;
*)
    echo "Kustomize: unsupported arch $ARCH, skipping"
    kustomize_arch=""
    ;;
esac

if [ -n "${kustomize_arch:-}" ]; then
    tarball=$(get_github_release_asset "kubernetes-sigs/kustomize" "^kustomize_.*_linux_${kustomize_arch}\\.tar\\.gz$")
    tar xzf "$tarball" -C /usr/local/bin/ kustomize
    rm -f "$tarball"
fi

########################################################################
# Virtctl (KubeVirt)
# https://kubevirt.io/
# Supports: amd64, arm64
########################################################################

case "$ARCH" in
x86_64) virtctl_arch="amd64" ;;
aarch64 | arm64) virtctl_arch="arm64" ;;
*)
    echo "Virtctl: unsupported arch $ARCH, skipping"
    virtctl_arch=""
    ;;
esac

if [ -n "${virtctl_arch:-}" ]; then
    bin=$(get_github_release_asset "kubevirt/kubevirt" "^virtctl-v[0-9]+\\.[0-9]+\\.[0-9]+-linux-${virtctl_arch}$")
    install -m 755 "$bin" /usr/local/bin/virtctl
    rm -f "$bin"
fi

########################################################################
# Packer
# https://developer.hashicorp.com/packer
########################################################################

case $ID in
ubuntu | debian)
    add_repo "hashicorp" \
        "https://apt.releases.hashicorp.com/gpg" \
        "https://apt.releases.hashicorp.com $VERSION_CODENAME main"
    install_pkg packer
    ;;
fedora)
    add_repo https://rpm.releases.hashicorp.com/fedora/hashicorp.repo
    install_pkg packer
    ;;
rocky)
    add_repo "https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo"
    install_pkg packer
    ;;
arch)
    install_pkg packer
    ;;
*)
    echo "Packer: unsupported distro $ID, skipping"
    ;;
esac
