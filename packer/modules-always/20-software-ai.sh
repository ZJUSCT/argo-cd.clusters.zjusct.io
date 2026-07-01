#!/usr/bin/env bash
# AI Coding Assistants

# shellcheck disable=SC1091
source /run/header

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
