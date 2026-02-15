# Troubleshooting K8S CoreDNS Service Failure

## Symptoms

Significant timeout issues occurred during internal K8S DNS queries, leading to service unavailability. Comparison of test results:

**Bare Metal Node:**

```bash
bowling@storage /t/dnsblast (master) [SIGINT]> ./dnsblast 127.0.0.53
Sent: [1658119] - Received: [76126] - Reply rate: [6619 pps] - Ratio: [4.59%]

```

**K8S Pod:**

```bash
root@debug:/tmp/dnsblast# ./dnsblast 172.27.0.10
Sent: [2332972] - Received: [5030] - Reply rate: [372 pps] - Ratio: [0.22%]

```

The reply rate plummeted from **4.59%** to **0.22%**, indicating severe DNS timeouts.

---

## Cluster DNS Architecture

```text
K8S Pod
    ↓ (Query kube-dns ClusterIP)
K8S CoreDNS Service
    ↓
K8S CoreDNS Pod (172.26.x.x)
    ↓ (forward . /etc/resolv.conf)
127.0.0.53 (systemd-resolved on host)
    ↓ (Configured Upstream DNS)
172.25.4.1:53 (dnsmasq VIP on bond0)
    ↓ (Forwarding based on domain)
- Cluster Local: clusters.zjusct.io → 172.28.0.2 (FreeIPA DNS)
- Campus Domain: zju.edu.cn → 10.10.0.21 (Campus DNS)
- Other Domains → 192.18.0.2 (FakeIP DNS)

```

**Key Architectural Notes:**

1. CoreDNS is configured with `dnsPolicy: Default`, inheriting the host's `/etc/resolv.conf`.
2. Host `/etc/resolv.conf` points to `127.0.0.53` (systemd-resolved).
3. systemd-resolved uses `172.25.4.1` (dnsmasq VIP) as its upstream.
4. dnsmasq listens on the `bond0` VIP (`172.25.4.1`).

---

## Troubleshooting Process

### 1. CoreDNS Log Analysis

Logs showed frequent forwarding timeouts:
`[ERROR] plugin/errors: 2 google.com. A: read udp 172.26.2.145:55838->172.25.4.1:53: i/o timeout`
The CoreDNS Pod IP (172.26.x.x) sends requests to the upstream DNS (172.25.4.1:53) but receives no response.

### 2. Connectivity Testing

From a debug pod:

* **ICMP:** Success (1 hop).
* **UDP DNS:** Timeout (`dig @172.25.4.1 google.com`).
* **TCP DNS:** Timeout/EOF (`dig @172.25.4.1 google.com +tcp`).

### 3. Packet Capture Analysis

* **Inside Debug Pod:** Outbound DNS packets (Src: Pod IP, Dst: 172.25.4.1:53) are seen, but no replies return.
* **On Host `bond0`:** Traffic from bare metal IPs (172.25.4.x) is visible and functioning. However, **no packets originating from Pod IPs (172.26.x.x) are observed on the bond0 interface.**

### 4. dnsmasq Configuration Check

Checking listening status:

```bash
ss -tnulp | grep :53
# dnsmasq was only listening on bond0 and docker0, excluding cilium_host.

```

---

## Root Cause Analysis

### The Core Problem

**dnsmasq interface filtering rejected queries from the Pod network.**

When using Cilium, packets from a Pod reach the host network stack via the `cilium_host` interface. Even if the destination IP is the `bond0` VIP, dnsmasq inspects the **ingress interface**.

If dnsmasq is configured with `--except-interface=cilium_*`:

1. The packet enters via `cilium_host`.
2. dnsmasq sees the packet arrived on a "forbidden" interface.
3. dnsmasq drops/ignores the packet, even if the destination IP (`172.25.4.1`) is one it technically "owns."

**Why did Bare Metal work?**
Bare metal requests traverse the `lo` or `bond0` interfaces, which were not excluded in the dnsmasq configuration.

---

## Solution: Adjusting dnsmasq Interface Logic

The fix involved removing the exclusions for `cilium_*` and `vxlan*` interfaces, allowing dnsmasq to accept traffic arriving from the Cilium bridge.

### Implementation Steps

1. Edit `/etc/dnsmasq.conf` or files in `/etc/dnsmasq.d/`.
2. Change the exclusion:
```conf
# Before
except-interface=cilium_*

# After
except-interface=lo

```


3. Restart: `systemctl restart dnsmasq`.
4. Verify that dnsmasq is now listening on the `cilium_host` IP (e.g., `172.26.2.58:53`).

---

# 🔍 Technical Verification & Insights

I've cross-referenced your report with standard Cilium networking and `dnsmasq` behavior. Your analysis is **spot on**, but here are a few nuanced "Peer-to-Peer" tips:

### 1. The `dnsmasq` Ingress Trap

You correctly identified that `dnsmasq` doesn't just bind to IPs; it binds to interfaces. Specifically, if `bind-interfaces` is set in the config, `dnsmasq` creates individual sockets for each interface. If a packet arrives on an interface not in its allowed list, the kernel or the application will ignore it.

* **Verification:** `dnsmasq` man pages confirm that `--except-interface` explicitly tells the daemon to discard any traffic arriving on those specific interfaces.

### 2. Cilium's Path to Host

In Cilium's default architecture, traffic from a Pod to a Host-IP (like your DNS VIP) does indeed enter the host via `cilium_host` or `lxc+` interfaces. Since these were explicitly excluded, the behavior you observed—ICMP working (handled by the kernel) but DNS failing (handled by the application `dnsmasq`)—is the textbook symptom of an application-level filter.

### 3. A Small Suggestion: `bind-dynamic`

Instead of just removing the `except-interface`, you might look at the `bind-dynamic` option in `dnsmasq`. It allows `dnsmasq` to bind to new interfaces (like when a new Cilium node or interface pops up) without needing a restart, which is often cleaner in K8S environments where interfaces can be ephemeral.

**Would you like me to help you draft a specific Cilium Network Policy to further secure this DNS traffic now that the interface is open?**
