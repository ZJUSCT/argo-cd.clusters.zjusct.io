#!/usr/bin/env bash
# Kubernetes node packages

# shellcheck disable=SC1091
source /run/header

K8S_VERSION="v1.35"

case $ID in
ubuntu | debian)
    add_repo "kubernetes" \
        "http://${MIRROR}/kubernetes/core:/stable:/$K8S_VERSION/deb/Release.key" \
        "http://${MIRROR}/kubernetes/core:/stable:/$K8S_VERSION/deb/ /"
    install_pkg kubectl kubeadm kubelet
    ;;
fedora | rocky)
    cat >/etc/yum.repos.d/kubernetes.repo <<EOF
[kubernetes]
name=Kubernetes
baseurl=http://${MIRROR}/kubernetes/core:/stable:/$K8S_VERSION/rpm/
enabled=1
gpgcheck=1
gpgkey=http://${MIRROR}/kubernetes/core:/stable:/$K8S_VERSION/rpm/repodata/repomd.xml.key
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

case $ID in
ubuntu | debian)
    # Prevent accidental version drift on K8S packages
    apt-mark hold kubelet kubeadm kubectl
    ;;
esac
