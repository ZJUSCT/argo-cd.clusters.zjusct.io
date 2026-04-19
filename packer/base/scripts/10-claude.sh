#!/bin/bash
set -e

DOWNLOAD_BASE_URL="https://downloads.claude.ai/claude-code-releases"
INSTALL_DIR="${1:-/usr/local/bin}"

# Detect platform
case "$(uname -s)" in
    Darwin) os="darwin" ;;
    Linux)  os="linux" ;;
    *)      echo "Unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac

case "$(uname -m)" in
    x86_64|amd64)   arch="x64" ;;
    arm64|aarch64)  arch="arm64" ;;
    *)              echo "Unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac

if [ "$os" = "darwin" ] && [ "$arch" = "x64" ] && [ "$(sysctl -n sysctl.proc_translated 2>/dev/null)" = "1" ]; then
    arch="arm64"
fi

if [ "$os" = "linux" ] && (ldd /bin/ls 2>&1 | grep -q musl); then
    platform="linux-${arch}-musl"
else
    platform="${os}-${arch}"
fi

mkdir -p "$INSTALL_DIR"
dest="$INSTALL_DIR/claude"

# Download latest binary directly to destination via temp fd
version=$(curl -fsSL "$DOWNLOAD_BASE_URL/latest")
curl -fsSL -o "$dest" "$DOWNLOAD_BASE_URL/$version/$platform/claude"

# Verify checksum
checksum=$(curl -fsSL "$DOWNLOAD_BASE_URL/$version/manifest.json" \
    | jq -r ".platforms[\"$platform\"].checksum // empty")
if [ -z "$checksum" ] || [[ ! "$checksum" =~ ^[a-f0-9]{64}$ ]]; then
    echo "Platform $platform not found in manifest" >&2; exit 1
fi

actual=$(sha256sum "$dest" | cut -d' ' -f1)
if [ "$actual" != "$checksum" ]; then
    echo "Checksum mismatch: expected $checksum, got $actual" >&2
    rm -f "$dest"; exit 1
fi

chmod 755 "$dest"
echo "Installed claude $version ($platform) to $dest"
