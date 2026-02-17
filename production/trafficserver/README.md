# trafficserver

Apache Traffic Server caching proxy with SSL bumping via `certifier.so`.

## Installing the CA Certificate on Debian/Ubuntu Clients

ATS signs HTTPS connections with a self-signed CA managed by cert-manager.
Clients must trust this CA to avoid certificate errors.

### 1. Fetch the CA certificate from the cluster

```bash
kubectl get secret trafficserver-ca -n trafficserver \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > trafficserver-ca.crt
```

### 2. Copy to the target host

```bash
scp trafficserver-ca.crt user@host:/usr/local/share/ca-certificates/trafficserver-ca.crt
```

Or inline over SSH:

```bash
kubectl get secret trafficserver-ca -n trafficserver \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | \
  ssh user@host "sudo tee /usr/local/share/ca-certificates/trafficserver-ca.crt > /dev/null"
```

### 3. Install on the host

```bash
sudo update-ca-certificates
```

Expected output includes: `1 added`.

### 4. Configure the proxy

Set the proxy environment variables (add to `/etc/environment` or a shell profile for persistence):

```bash
export http_proxy=http://<LOADBALANCER-IP>:8080
export https_proxy=http://<LOADBALANCER-IP>:8080
export no_proxy=localhost,127.0.0.1
```

For APT specifically (`/etc/apt/apt.conf.d/01proxy`):

```
Acquire::http::Proxy "http://<LOADBALANCER-IP>:8080";
Acquire::https::Proxy "http://<LOADBALANCER-IP>:8080";
```

### Verify

```bash
curl -v https://example.com
# Should show "issuer: CN=trafficserver-ca" in the certificate chain
```

### Notes

- The CA certificate rotates whenever cert-manager renews it (default: 90 days before expiry).
  Re-run the steps above after each rotation.
- The LoadBalancer IP is assigned by MetalLB; check with:
  `kubectl get svc trafficserver -n trafficserver`
