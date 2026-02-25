# trafficserver

Apache Traffic Server caching proxy with SSL bumping via `certifier.so`.

LoadBalancer IP: `<LOADBALANCER-IP>:8080`

## Forward proxy vs. reverse proxy

ATS defaults to **reverse proxy mode** (`remap_required=1`): every request must
match a rule in `remap.config`, otherwise ATS returns 404. This is appropriate
for accelerating known backends.

For a caching forward proxy, `records.yaml` sets `remap_required=0`. ATS then
forwards any request it receives without requiring an explicit mapping.

## Verifying the proxy works

```bash
# Basic test — CONNECT tunnel should return 200, then the real response follows
curl -x http://<LOADBALANCER-IP>:8080 https://www.google.com -sk -I

# Check cache headers (run twice; second request should show X-Cache: hit-fresh)
for i in 1 2; do
  echo "--- $i ---"
  curl -x http://<LOADBALANCER-IP>:8080 https://releases.ubuntu.com/jammy/SHA256SUMS -skI \
    | grep -E "HTTP/|X-Cache|Age"
done

# Confirm ATS is SSL-bumping (issuer should be trafficserver-ca, not the real CA)
curl -x http://<LOADBALANCER-IP>:8080 https://example.com -sk -v 2>&1 | grep issuer

# Read access logs (binary format, use traffic_logcat to decode)
kubectl exec -n trafficserver deploy/trafficserver -- \
  traffic_logcat /opt/var/log/trafficserver/squid.blog
```

## Installing the CA certificate on Debian/Ubuntu clients

ATS re-signs HTTPS responses with a self-signed CA. Clients must trust it.

```bash
# 1. Fetch from the cluster
kubectl get secret trafficserver-ca -n trafficserver \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > trafficserver-ca.crt

# 2. Install on target host
sudo cp trafficserver-ca.crt /usr/local/share/ca-certificates/trafficserver-ca.crt
sudo update-ca-certificates
# Expected output: "1 added"
```

Or inline over SSH:

```bash
kubectl get secret trafficserver-ca -n trafficserver \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | \
  ssh user@host "sudo tee /usr/local/share/ca-certificates/trafficserver-ca.crt > /dev/null \
    && sudo update-ca-certificates"
```

## Configuring clients to use the proxy

`/etc/environment`:

```bash
http_proxy=http://<LOADBALANCER-IP>:8080
https_proxy=http://<LOADBALANCER-IP>:8080
no_proxy=localhost,127.0.0.1
```

APT only (`/etc/apt/apt.conf.d/01proxy`):

```
Acquire::http::Proxy "http://<LOADBALANCER-IP>:8080";
Acquire::https::Proxy "http://<LOADBALANCER-IP>:8080";
```

## Notes

- The CA cert is managed by cert-manager and rotates automatically. Re-run the
  install steps on clients after each rotation.
- `certifier.so` stores generated certs in `/tmp` (ephemeral). They are
  regenerated on pod restart with no data loss.
