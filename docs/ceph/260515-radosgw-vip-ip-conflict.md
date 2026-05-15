# RGW hostNetwork 与 keepalived VIP IP 冲突导致间歇性连接失败

**Date:** 2026-05-15
**Cluster:** Rook-Ceph v1.19.1, Ceph 19.2.3 (Squid)
**Affected service:** radosgw (`radosgw.clusters.zjusct.io`)

---

## Summary

RGW pod 被分配了与 keepalived VIP 相同的 IP（`172.25.4.1`），导致约 50% 的 S3 请求被路由到持有 VIP 的 m601 节点而非实际的 pod。m601 上无服务监听 80 端口，返回 Connection Refused。根因是 RGW 从 CephCluster 级 `network.provider: host` 继承了 hostNetwork 模式，而 Cilium pod CIDR 未覆盖 `172.25.4.0/24` 网段，pod IP 落入 VIP 范围。

---

## Root Cause

### 架构背景

集群三节点以 keepalived + haproxy 管理 K8S API Server VIP：

| VIP | 用途 | 当前持有 |
|---|---|---|
| `172.25.4.1` | K8S API Server | m601 (priority 61) |

CephCluster 配置 `network.provider: host`，使所有 Ceph daemon（MON、OSD、MGR、RGW）使用 hostNetwork 模式。keepalived VIP 均在 `172.25.4.0/24` 子网内，由节点 bond0 接口承载。

### 触发条件

1. RGW 未显式设置 `gateway.hostNetwork`，通过 Rook 源码（`pkg/apis/ceph.rook.io/v1/object.go:59`）fallback 到集群级 `network.provider: host`
2. RGW pod 使用 hostNetwork 时，K8S 将其 podIP 报告为宿主机上的可用 IP
3. 宿主机曾短暂持有 VIP `172.25.4.1`（keepalived 漂移），pod 恰好在此窗口期被调度，获取了该 IP
4. VIP 漂移回 m601 后，pod 在 K8S 中仍登记为 `172.25.4.1`

### 故障机制

```
Client → Envoy LB (172.28.0.1) → Envoy Proxy → Service ClusterIP
                                                        │
                                          ┌─────────────┴─────────────┐
                                          ▼                           ▼
                                   172.25.4.1:80              172.25.4.11:80
                                   (VIP, m601)                (RGW pod, storage)
                                          │                           │
                                   ARP → m601 MAC              ARP → storage MAC
                                          │                           │
                                   haproxy:6444 only            radosgw:80
                                          │                           │
                                   TCP RST                     HTTP 200
```

- 所有节点 ARP 表将 `172.25.4.1` 解析为 m601 bond0 MAC（`f6:e5:03:9b:81:4d`）
- m601 上仅 haproxy 监听 `172.25.4.1:6444`，**无进程监听 80 端口**
- Service 两 endpoint 各承担 ~50% 流量 → 间歇性 50% 失败率

### 流量差异

RGW 单个 pod（IP 冲突的那个）CPU 仅 8m，而另一 pod 322m，印证了冲突 pod 几乎未收到实际流量。

---

## Fix

在 `values/rook-ceph-cluster-v1.19.1.yaml` 的 `cephObjectStores[0].spec.gateway` 下添加 `hostNetwork: false`：

```yaml
cephObjectStores:
  - name: ceph-objectstore
    spec:
      gateway:
        port: 80
        hostNetwork: false    # 覆盖集群级 network.provider: host
        resources: ...
```

GatewaySpec 中的 `HostNetwork *bool` 字段（`types.go:1991`）是 Rook 官方提供的 per-daemon 覆盖机制，注释明确写道：

> _If not set, the network settings from the cluster CR will be applied._

关闭 RGW 的 hostNetwork 后，pod 从 Cilium pod CIDR 获取 IP，不再与 keepalived VIP 竞争。MON/OSD/MGR 继续使用 hostNetwork 服务裸金属节点。

---

## Verification

修复后 RGW endpoints：

```
旧：172.25.4.1:80（VIP 冲突）, 172.25.4.11:80
新：172.25.4.61:80（m601 真实 IP）, 172.25.4.11:80（storage 真实 IP）
```

minio-client 连续 10 次测试均成功，无复现。

---

## Key Takeaways

1. **hostNetwork 与 VIP 在同一子网时存在天然的 IP 冲突风险**。任何使用 hostNetwork 的 pod 都可能分配到 VIP 地址，尤其是 VIP 漂移窗口期。
2. **Rook 的 `network.provider: host` 不应被视为全局不可改变的默认值**。对于不需要裸金属直接访问的服务（如 RGW），应显式设置 `gateway.hostNetwork: false`。
3. **排查此类问题时，两侧信息（客户端 + 服务端 + 网络）缺一不可**。本次通过 `ip neigh`（ARP 表）、`ss -tlnp`（端口监听）、直接 IP 连通性测试三管齐下确定了根因。
