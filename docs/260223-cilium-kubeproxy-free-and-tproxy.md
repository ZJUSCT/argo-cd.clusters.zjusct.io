# Cilium kube-proxy 替代迁移与 tproxy nftables 配置

**Date:** 2026-02-23
**Status:** ✅ Successful

## Overview

本次迁移将集群的 K8S 服务流量处理从 kube-proxy（iptables）切换到 Cilium 的 eBPF kube-proxy 替代，并同步设计了与透明代理（tproxy）coexist 的 nftables 配置。迁移目标是为后续在三个控制节点上部署 tproxy 透明代理打通技术路径，确保两者不冲突。

## 集群基础信息

| 项目 | 值 |
|------|---|
| Cilium 版本 | 1.19.0 |
| Cilium namespace | `default`（非 kube-system） |
| 节点数 | 3 控制节点（m600/m601/storage），无独立 worker |
| 内核版本 | Ubuntu 24.04（6.8.0）× 2，Debian 13（6.12.63）× 1 |
| API Server VIP | `172.25.4.1:6444`（keepalived，`k8s-api.clusters.zjusct.io`） |
| Pod CIDR | `172.26.0.0/16` |
| Service CIDR | `172.27.0.0/16` |
| Tunnel 模式 | VXLAN |

---

## Part 1：Cilium kube-proxy 替代迁移

### 迁移前状态

```
KubeProxyReplacement: False
Routing: Tunnel [vxlan], Host: Legacy
Masquerading: IPTables [IPv4]
Socket LB: Disabled
```

kube-proxy DaemonSet 运行在 `kube-system` 命名空间，不受 ArgoCD 管理（由 kubeadm 部署）。

### Cilium values 修改（`production/default/values/cilium-1.19.0.yaml`）

| 字段 | 旧值 | 新值 | 原因 |
|------|------|------|------|
| `kubeProxyReplacement` | `"false"` | `"true"` | 启用功能 |
| `k8sServiceHost` | `""` | `"172.25.4.1"` | **必须**：Cilium 需要直连 API Server，不能依赖 ClusterIP |
| `k8sServicePort` | `""` | `"6444"` | API Server VIP 端口 |
| `socketLB.enabled` | `false` | `true` | kube-proxy replacement 依赖 socket-LB |
| `bpf.masquerade` | `~` | `true` | 避免 BPF NodePort 与 iptables SNAT 端口冲突 |

> **关键点：`k8sServiceHost` 为何必须设置？**
>
> Cilium agent 启动时需要直连 Kubernetes API Server 进行 bootstrap。在 kube-proxy 被移除后，`kubernetes` ClusterIP（`172.27.0.1:443`）由 Cilium 自身的 eBPF 规则接管。如果没有 `k8sServiceHost`，agent 在 bootstrap 阶段无法找到 API Server（此时 eBPF 规则尚未初始化）。
>
> 本集群 API Server 通过 keepalived VIP `172.25.4.1:6444` 提供 HA，直接使用 VIP IP 而非 hostname，避免 DNS 解析依赖。

### 迁移执行步骤

```bash
# 1. 修改 values 文件，commit + push（GitOps）
# ArgoCD 自动同步 → Cilium DaemonSet 滚动重启
kubectl rollout status daemonset/cilium -n default

# 2. 验证 kube-proxy replacement 已生效（在移除 kube-proxy 之前）
kubectl -n default exec ds/cilium -- cilium-dbg status | grep KubeProxyReplacement
# 期望输出：KubeProxyReplacement: True [bond0 ...]

# 3. 删除 kube-proxy（非 GitOps 管理，直接 kubectl）
kubectl -n kube-system delete ds kube-proxy
kubectl -n kube-system delete cm kube-proxy

# 4. 清理各节点残留 iptables KUBE-* 规则
iptables-save | grep -v KUBE | iptables-restore
```

### 迁移后状态验证

```
KubeProxyReplacement: True [bond0  172.25.4.11 ...]
Routing:              Tunnel [vxlan], Host: BPF      ← Legacy → BPF
Masquerading:         BPF [bond0]                    ← IPTables → BPF
Socket LB:            Enabled
  - ClusterIP:    Enabled
  - NodePort:     Enabled (Range: 30000-32767)
  - LoadBalancer: Enabled
  - externalIPs:  Enabled
  - HostPort:     Enabled
```

### Rook-Ceph 影响分析

Ceph 部署使用 `provider: host` 网络（`spec.network.provider: host`），绝大多数 Pod（OSDs、MONs、MDSes、MGRs 等）使用 `hostNetwork: true`，通过主机 IP（`172.25.4.x`）直接通信，完全绕过 Kubernetes Service 系统。

| 组件 | hostNetwork | 影响评估 |
|------|-------------|----------|
| OSD（20+）、MON（3）、MDS（4）、MGR（2）等 | ✅ true | **不受影响**：通信走主机 IP，与 K8S 服务路由无关 |
| rook-ceph-operator、ceph-csi-controller-manager | ❌ false | 极短重连（秒级），不影响数据 |
| rbd/cephfs-ctrlplugin | ❌ false | 通过 Ceph 主机 IP 访问，不受影响 |
| RGW S3 ClusterIP 服务 | — | 迁移期间秒级中断（Mimir 对象存储可能短暂报错） |

**结论：Ceph 数据层面零风险。** Ceph 内部通信（quorum、数据复制、I/O）完全在主机网络层面运行，与 kube-proxy/Cilium 服务路由无关。

#### libceph 与 socket-LB 兼容性

Cilium 文档曾提到：启用 socket-LB 的 kube-proxy replacement 与 libceph 一起使用时，需要 `getpeername(2)` hook 支持。本集群内核版本（6.8、6.12）以及 Cilium 1.19.0 均已完全支持，无需额外配置。

---

## Part 2：Cilium eBPF 与 tproxy nftables 的协作设计

### 为什么迁移到 kube-proxy replacement 能消除与 tproxy 的冲突？

**问题根源（迁移前）：**
kube-proxy 在 netfilter 的 iptables 框架内写入 `KUBE-SVC-*`、`KUBE-SEP-*` 等 NAT 链。tproxy 同样通过 nftables/iptables 在 netfilter 中操作，两者在同一处理层面，规则交互复杂，DNAT 顺序和 TPROXY 目标可能相互干扰。

**迁移后的流量分层：**

```
出向流量（Pod/Host → Service/Internet）：
  ┌─ [1] cgroup eBPF hook (socket-LB) ─────── Cilium 在这里
  │       connect() 时重写 ClusterIP → Pod IP
  │       数据包进入网络栈时目标已是 Pod IP
  │
  ├─ netfilter OUTPUT / PREROUTING ─────────── nftables tproxy 在这里
  │       看到的目标是 Pod IP（在 reserved_ip 范围内），直连
  │       不会触发 ClusterIP/Service 相关规则
  │
  └─ [2] TC egress eBPF ────────────────────── Cilium 在这里

入向流量（External → NodePort）：
  ┌─ NIC → [3] TC ingress eBPF ─────────────── Cilium 在这里（先于 netfilter）
  │       DNAT: NodePort → Pod IP
  │
  └─ netfilter PREROUTING ──────────────────── nftables tproxy 在这里
          目标已是 Pod IP（reserved_ip），直连
```

**核心结论：**
- Socket-LB 在 `connect()` 系统调用时就完成服务解析，nftables 永远看不到以 ClusterIP 为目标的出向数据包
- TC ingress 先于 netfilter PREROUTING 运行，NodePort 流量在到达 nftables 之前已完成 DNAT
- 删除 kube-proxy 后，netfilter 内不再存在任何 `KUBE-*` 链，彻底消除与 tproxy nftables 的干扰

### nftables tproxy 配置要点

配置文件：`config/nftables-tproxy-k8s`

#### reserved_ip 覆盖范围

`172.16.0.0/12` 覆盖 `172.16.0.0` 至 `172.31.255.255`，包含本集群所有内部网段：

| 网段 | 用途 |
|------|------|
| `172.25.4.0/24` | K8S 节点 IP |
| `172.25.4.1` | Keepalived VIP |
| `172.26.0.0/16` | K8S Pod CIDR |
| `172.27.0.0/16` | K8S Service CIDR |

因此无需单独为 K8S 相关网段创建 set，`reserved_ip` 的一条 `172.16.0.0/12` 条目即可覆盖全部。

#### Pod 源地址检查的必要性

`172.26.0.0/16`（Pod CIDR）虽然包含在 `reserved_ip`（目标地址检查），但 `reserved_ip` 只检查**目标**地址。Pod 流量需要通过**源**地址检查来排除：Pod 发出的对外流量（如访问互联网），目标是公网 IP，不在 `reserved_ip` 内，若没有源地址检查，会被错误地导入 tproxy。

```nft
# 必须保留：源地址检查，语义与 reserved_ip（目标检查）不同
meta l4proto { tcp, udp } ip saddr @k8s_pod_cidr counter return
```

#### Keepalived HA tproxy 路由设计

```nft
define TPROXY_VIP  = 172.25.4.1
define TPROXY_PORT = 7892
...
meta l4proto { tcp, udp } meta mark set 1 tproxy ip to $TPROXY_VIP:$TPROXY_PORT counter accept
```

`tproxy ip to ADDR:PORT` 查找绑定到 `ADDR`（或 `0.0.0.0`）的本地 socket，行为由 tproxy 进程的绑定地址决定：

| tproxy 绑定地址 | VIP 节点 | 非 VIP 节点 | 适用场景 |
|------|---------|------------|---------|
| `172.25.4.1`（VIP 地址） | ✅ 代理生效 | ❌ 无 socket，静默跳过，流量直连 | keepalived 联动，严格主备 |
| `0.0.0.0`（所有接口） | ✅ 代理生效 | ✅ 各节点独立代理 | 三节点完全对等，各自处理本地流量 |

推荐在 keepalived 的 `notify_master` / `notify_backup` 脚本中控制 tproxy 进程绑定到 VIP 地址，实现严格主备切换。

#### Cilium 与 tproxy mark 不冲突

Cilium 在 `ip mangle` 表的 `CILIUM_PRE_mangle` 链中使用 mark 掩码 `0x00000f00`（值如 `0x200`、`0x800`、`0xe00`）。tproxy 使用 mark `0x00000001`，位于完全不同的 bit 范围，不存在冲突。

#### VRRP 心跳不受影响

Keepalived VRRP 心跳目标为组播地址 `224.0.0.18`，属于 `224.0.0.0/4`，已在 `reserved_ip` 中排除，nftables 规则不会干扰 keepalived 的 HA 功能。

### 必要的路由配置（每节点）

```bash
# tproxy 需要策略路由将标记流量引导至本地 socket
ip -4 rule add fwmark 1 lookup 100
ip -4 route add local 0.0.0.0/0 dev lo table 100
```

建议通过 systemd 服务或 keepalived 脚本持久化这些路由规则。

---

## 迁移检查清单

- [x] 确认 API Server VIP 地址和端口（`172.25.4.1:6444`）
- [x] 在 cilium values 中设置 `k8sServiceHost`、`k8sServicePort`
- [x] 启用 `kubeProxyReplacement: "true"`、`socketLB.enabled: true`、`bpf.masquerade: true`
- [x] 通过 GitOps 提交并触发 ArgoCD 同步
- [x] 等待 Cilium DaemonSet 滚动更新完成（kube-proxy 仍运行期间）
- [x] 验证 `KubeProxyReplacement: True`
- [x] 删除 kube-proxy DaemonSet 和 ConfigMap
- [x] 清理各节点残留 iptables KUBE-* 规则
- [x] 验证最终状态：所有 Service 类型由 Cilium eBPF 接管，Masquerading 为 BPF 模式

## Troubleshooting

### ArgoCD repo-server CrashLoopBackOff 导致无法同步

**现象：** `argocd app sync` 报 `connection refused` to repo-server ClusterIP。

**原因：** repo-server 因 liveness probe 超时（health check context canceled）不断重启，处于 5m0s 退避期。

**解法：**
```bash
# 删除 crashing pod，重置退避计时器
kubectl -n argo-cd delete pod <repo-server-pod>
# 等待新 pod 2/2 Running 后触发同步
kubectl -n argo-cd patch app <appname> --type merge -p \
  '{"operation": {"initiatedBy": {"username": "admin"}, "sync": {"revision": "HEAD"}}}'
```

### 验证 kube-proxy replacement 状态

```bash
# 完整状态
kubectl -n default exec ds/cilium -- cilium-dbg status --verbose | grep -A20 "KubeProxyReplacement"

# 查看 Cilium 管理的服务列表
kubectl -n default exec ds/cilium -- cilium-dbg service list

# 确认 kube-proxy 已删除
kubectl -n kube-system get ds kube-proxy 2>/dev/null || echo "NOT FOUND ✓"
```

## 参考资料

- [Cilium kube-proxy Free Guide](https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/)
- `config/nftables-tproxy-k8s` — tproxy nftables 配置（带详细注释）
