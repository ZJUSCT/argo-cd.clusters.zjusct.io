#!/usr/bin/env bash
# Kubernetes node container runtime, kernel modules, sysctl, and swap configuration
# https://kubernetes.io/docs/setup/production-environment/container-runtimes/

# shellcheck disable=SC1091
source /run/header

########################################################################
# Containerd
########################################################################

install -D -m 0644 /dev/stdin /etc/containerd/config.toml <<'EOF'
version = 2

[plugins."io.containerd.grpc.v1.cri".cni]
bin_dir = "/opt/cni/bin"
conf_dir = "/etc/cni/net.d"
[plugins."io.containerd.cri.v1.runtime".containerd.runtimes.runc]
cgroup_writable = true
[plugins."io.containerd.cri.v1.runtime".containerd.runtimes.runc.options]
SystemdCgroup = true
EOF

install -D -m 0644 /dev/stdin /etc/crictl.yaml <<'EOF'
runtime-endpoint: "unix:///var/run/containerd/containerd.sock"
image-endpoint: "unix:///var/run/containerd/containerd.sock"
timeout: 10
EOF

systemctl enable containerd

########################################################################
# Kernel modules
########################################################################

install -D -m 0644 /dev/stdin /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF

modprobe --dry-run overlay
modprobe --dry-run br_netfilter

########################################################################
# Sysctl parameters
########################################################################

install -D -m 0644 /dev/stdin /etc/sysctl.d/k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
net.ipv4.ip_nonlocal_bind=1
# production
net.core.somaxconn                    = 32768
net.ipv4.tcp_max_syn_backlog          = 16384
net.ipv4.tcp_tw_reuse                 = 1
fs.inotify.max_user_watches           = 524288
fs.inotify.max_user_instances         = 8192
kernel.pid_max                        = 4194303
net.netfilter.nf_conntrack_max        = 1000000
EOF

sysctl --dry-run --ignore --load=/etc/sysctl.d/k8s.conf >/dev/null

########################################################################
# Disable swap
########################################################################

systemctl mask swap.target
