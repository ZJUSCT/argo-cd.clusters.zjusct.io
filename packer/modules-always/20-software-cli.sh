#!/usr/bin/env bash
# CLI Tools

# shellcheck disable=SC1091
source /tmp/00-shared.sh

########################################################################
# zellij: tmux alternative
# https://github.com/zellij-org/zellij/releases
########################################################################

case "$(uname -m)" in
x86_64)
    zellij_pattern="^zellij-x86_64-unknown-linux-musl\\.tar\\.gz$"
    ;;
aarch64 | arm64)
    zellij_pattern="^zellij-aarch64-unknown-linux-musl\\.tar\\.gz$"
    ;;
esac

if [ -n "${zellij_pattern:-}" ]; then
    tarball=$(get_github_release_asset "zellij-org/zellij" "$zellij_pattern")
    tar xzf "$tarball" -C /usr/local/bin/ zellij
    rm -f "$tarball"
fi
