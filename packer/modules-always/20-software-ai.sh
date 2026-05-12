#!/usr/bin/env bash
# AI Coding Assistants

# shellcheck disable=SC1091
source /run/header

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
    if [ "$MUSL" = 1 ]; then
        claude_platform="linux-${claude_arch}-musl"
    else
        claude_platform="linux-${claude_arch}"
    fi

    version=$(curl -fsSL "$DOWNLOAD_BASE_URL/latest")
    curl -fsSL -o /usr/local/bin/claude "$DOWNLOAD_BASE_URL/$version/$claude_platform/claude"

    checksum=$(curl -fsSL "$DOWNLOAD_BASE_URL/$version/manifest.json" |
        jq -r ".platforms[\"$claude_platform\"].checksum // empty")
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
    if [ "$MUSL" = 1 ]; then
        opencode_pattern="opencode-linux-x64-musl\\.tar\\.gz"
    else
        opencode_pattern="opencode-linux-x64\\.tar\\.gz"
    fi
    ;;
aarch64 | arm64)
    if [ "$MUSL" = 1 ]; then
        opencode_pattern="opencode-linux-arm64-musl\\.tar\\.gz"
    else
        opencode_pattern="opencode-linux-arm64\\.tar\\.gz"
    fi
    ;;
*)
    echo "OpenCode: unsupported arch $ARCH, skipping"
    ;;
esac

if [ -n "${opencode_pattern:-}" ]; then
    tarball=$(get_github_release_asset "anomalyco/opencode" "$opencode_pattern")
    tar xzf "$tarball" -C /usr/local/bin/ opencode
    rm -f "$tarball"
fi

########################################################################
# Codex (OpenAI)
# https://github.com/openai/codex
########################################################################

case "$ARCH" in
x86_64) codex_arch="x86_64" ;;
aarch64 | arm64) codex_arch="aarch64" ;;
*)
    echo "Codex: unsupported arch $ARCH, skipping"
    ;;
esac

if [ -n "${codex_arch:-}" ]; then
    codex_tarball=$(get_github_release_asset "openai/codex" \
        "codex-${codex_arch}-unknown-linux-musl\\.tar\\.gz")
    tar xzf "$codex_tarball" -C /tmp/
    install -m 755 "/tmp/codex-${codex_arch}-unknown-linux-musl" /usr/local/bin/codex
    rm -f "$codex_tarball" "/tmp/codex-${codex_arch}-unknown-linux-musl"
fi
