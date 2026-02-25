# Squid Forward Proxy

Squid forward proxy with SSL bumping (MITM) for HTTPS traffic inspection and caching.

## Service Details

- **LoadBalancer IP**: 172.28.0.4
- **Port**: 3128
- **Protocol**: HTTP proxy with SSL bumping

## Features

- **SSL Bumping**: MITM for HTTPS traffic inspection using self-signed CA certificate
- **Optimized Caching**: Special refresh patterns for:
  - APT packages (Packages, Sources, Release files)
- **Large Object Support**: Up to 32GB objects (for NVHPC runfiles, etc.)

## Client Configuration

### 1. Install CA Certificate

To avoid SSL certificate warnings, install the squid CA certificate on client machines:

```bash
# Extract CA certificate from Kubernetes secret
kubectl get secret squid-ca -n squid -o jsonpath='{.data.tls\.crt}' | base64 -d > squid-ca.crt

# Install on Ubuntu/Debian
sudo cp squid-ca.crt /usr/local/share/ca-certificates/squid-ca.crt
sudo update-ca-certificates

# Install on RHEL/CentOS
sudo cp squid-ca.crt /etc/pki/ca-trust/source/anchors/
sudo update-ca-trust
```

### 2. Configure Proxy Settings

#### System-wide (Linux)

Add to `/etc/environment`:

```bash
http_proxy=http://172.28.0.4:3128
https_proxy=http://172.28.0.4:3128
HTTP_PROXY=http://172.28.0.4:3128
HTTPS_PROXY=http://172.28.0.4:3128
no_proxy=localhost,127.0.0.1,.zju.edu.cn
NO_PROXY=localhost,127.0.0.1,.zju.edu.cn
```

#### APT (Ubuntu/Debian)

Create `/etc/apt/apt.conf.d/02proxy`:

```
Acquire::http::Proxy "http://172.28.0.4:3128";
Acquire::https::Proxy "http://172.28.0.4:3128";
```

#### Git

```bash
git config --global http.proxy http://172.28.0.4:3128
git config --global https.proxy http://172.28.0.4:3128
```

## Testing

### Basic Connectivity

```bash
# HTTP test
curl -x http://172.28.0.4:3128 http://www.google.com -I

# HTTPS test (with CA cert installed)
curl -x http://172.28.0.4:3128 https://www.google.com -I

# HTTPS test (without CA cert - will show certificate issuer)
curl -x http://172.28.0.4:3128 https://www.google.com -kv 2>&1 | grep issuer
# Should show: issuer: CN=ZJUSCT Squid Proxy CA
```

### Cache Testing

Run the same request twice - the second should be a cache HIT:

```bash
for i in 1 2; do
  echo "Request $i:"
  curl -x http://172.28.0.4:3128 https://releases.ubuntu.com/jammy/SHA256SUMS \
    -skI | grep -E "X-Cache"
done
```

Expected output:
```
Request 1:
X-Cache: MISS from squid
Request 2:
X-Cache: HIT from squid
```

## Troubleshooting

### Pod Fails to Start

Check init container logs:

```bash
kubectl logs -n squid deployment/squid -c init-squid
```

Common issues:
- Mirror download failures (mirrors.zju.edu.cn unreachable)
- ssl_db initialization errors

### Certificate Errors on Clients

1. Verify certificate is installed:
   ```bash
   openssl s_client -connect www.google.com:443 \
     -proxy 172.28.0.4:3128 2>&1 | grep -A2 "issuer"
   ```

2. Check certificate in Kubernetes:
   ```bash
   kubectl get certificate -n squid
   kubectl describe certificate squid-ca -n squid
   ```

### Corrupted Cache Entries (0-byte Responses)

**Symptoms:**
- Clients receive 0-byte files or empty responses
- APT fails with "NOSPLIT" errors on InRelease files
- Squid access log shows correct byte counts (e.g., `TCP_MEM_HIT/200 2132`) but clients get 0 bytes
- Multiple concurrent requests for the same file may fail

**Root Cause:**

This typically occurs when:
1. Origin CDN temporarily returns a 0-byte file (e.g., cache miss on CDN edge)
2. Squid caches this corrupt 0-byte response
3. Even with `refresh_pattern` revalidation, when origin returns "304 Not Modified", squid serves the corrupt cached object
4. The cache entry shows correct size in logs but delivers empty body to clients

**Solution: Purge Corrupted Cache Entry**

Execute inside the squid pod:

```bash
# Find and purge specific corrupted entries
kubectl exec -n squid deployment/squid -- \
  squid-purge -e 'https://developer\.download\.nvidia\.com/compute/cuda/repos/debian13/x86_64/InRelease' -P 1

# Or purge all entries matching a pattern
kubectl exec -n squid deployment/squid -- \
  squid-purge -e 'https://developer\.download\.nvidia\.com/.*' -P 1
```

**Verification:**

After purging, test that clients receive the correct file:

```bash
export http_proxy=http://172.28.0.4:3128
export https_proxy=http://172.28.0.4:3128
wget --no-check-certificate https://developer.download.nvidia.com/compute/cuda/repos/debian13/x86_64/InRelease
# Should download 1578 bytes, not 0 bytes
```

**Prevention:**

The squid configuration includes:
- `collapsed_forwarding on` - Merges concurrent requests to prevent race conditions
- `shared_transient_entries_limit 32768` - Increased for multi-worker setup (8 workers)

These settings reduce the likelihood of cache corruption from simultaneous requests, but cannot prevent caching of transiently corrupt responses from origin servers.

## References

- Original Docker Compose: `/home/bowling/jenkins.clusters.zjusct.io/services/squid`
- Squid Documentation: http://www.squid-cache.org/Doc/
- SSL Bumping: https://wiki.squid-cache.org/Features/SslBump
