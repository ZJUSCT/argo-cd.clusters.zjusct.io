#!/usr/bin/env bash
# shellcheck disable=SC1091
source /tmp/00-shared.sh

########################################################################
# Claude Code
# https://code.claude.com/docs/en/setup
########################################################################

DOWNLOAD_BASE_URL="https://downloads.claude.ai/claude-code-releases"

case "$ARCH" in
x86_64) claude_arch="x64" ;;
aarch64 | arm64) claude_arch="arm64" ;;
*)
    echo "Claude Code: unsupported arch $ARCH, skipping"
    ;;
esac

if [ -n "${claude_arch:-}" ]; then
    if ldd /bin/ls 2>&1 | grep -q musl; then
        claude_platform="linux-${claude_arch}-musl"
    else
        claude_platform="linux-${claude_arch}"
    fi

    version=$(curl -fsSL "$DOWNLOAD_BASE_URL/latest")
    curl -fsSL -o /usr/local/bin/claude "$DOWNLOAD_BASE_URL/$version/$claude_platform/claude"

    checksum=$(curl -fsSL "$DOWNLOAD_BASE_URL/$version/manifest.json" \
        | jq -r ".platforms[\"$claude_platform\"].checksum // empty")
    if [ -z "$checksum" ] || [[ ! "$checksum" =~ ^[a-f0-9]{64}$ ]]; then
        echo "Claude Code: platform $claude_platform not found in manifest" >&2
        rm -f /usr/local/bin/claude
    else
        actual=$(sha256sum /usr/local/bin/claude | cut -d' ' -f1)
        if [ "$actual" != "$checksum" ]; then
            echo "Claude Code: checksum mismatch, expected $checksum, got $actual" >&2
            rm -f /usr/local/bin/claude
        else
            chmod 755 /usr/local/bin/claude
            echo "Installed Claude Code $version ($claude_platform)"
        fi
    fi
fi

########################################################################
# OpenCode
# https://github.com/anomalyco/opencode
########################################################################

case "$ARCH" in
x86_64)
    install_tarball_from_github "anomalyco/opencode" "opencode-linux-x64-musl.tar.gz"
    ;;
aarch64 | arm64)
    install_tarball_from_github "anomalyco/opencode" "opencode-linux-arm64-musl.tar.gz"
    ;;
*)
    echo "OpenCode: unsupported arch $ARCH, skipping"
    ;;
esac

########################################################################
# Codex (OpenAI)
# https://github.com/openai/codex
########################################################################

case "$ARCH" in
x86_64)   codex_arch="x86_64" ;;
aarch64 | arm64) codex_arch="aarch64" ;;
*)
    echo "Codex: unsupported arch $ARCH, skipping"
    ;;
esac

if [ -n "${codex_arch:-}" ]; then
    codex_tmpdir=$(mktemp -d)
    if gh_release_download --repo "openai/codex" \
        --pattern "codex-${codex_arch}-unknown-linux-gnu.tar.gz" --dir "$codex_tmpdir"; then
        tar xzf "$codex_tmpdir"/*.tar.gz -C "$codex_tmpdir"
        rm "$codex_tmpdir"/*.tar.gz
        install -m 755 "$codex_tmpdir"/codex-* /usr/local/bin/codex
    fi
    rm -rf "$codex_tmpdir"
fi
