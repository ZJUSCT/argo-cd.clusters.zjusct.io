#!/usr/bin/env bash
# shellcheck disable=SC1091
source /tmp/00-shared.sh

########################################################################
# zellij: tmux alternative
# https://github.com/zellij-org/zellij/releases
########################################################################

case "$(uname -m)" in
x86_64)
    install_tarball_from_github "zellij-org/zellij" "zellij-x86_64-unknown-linux-musl.tar.gz"
    ;;
aarch64 | arm64)
    install_tarball_from_github "zellij-org/zellij" "zellij-aarch64-unknown-linux-musl.tar.gz"
    ;;
esac
