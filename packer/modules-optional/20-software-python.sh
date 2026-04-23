#!/usr/bin/env bash
# shellcheck disable=SC1091
source /tmp/00-shared.sh

########################################################################
# Python (distro packages)
########################################################################

case $ID in
ubuntu | debian)
    install_pkg python3 python3-pip python3-venv
    ;;
fedora | openEuler)
    install_pkg python3 python3-pip
    ;;
arch)
    install_pkg python python-pip
    ;;
*)
    echo "Python: unknown distro $ID, skipping"
    ;;
esac

########################################################################
# uv
# https://docs.astral.sh/uv/getting-started/installation/#standalone-installation
########################################################################

case "$ARCH" in
x86_64)
    if ldd /bin/ls 2>&1 | grep -q musl; then
        install_tarball_from_github "astral-sh/uv" "uv-x86_64-unknown-linux-musl.tar.gz"
    else
        install_tarball_from_github "astral-sh/uv" "uv-x86_64-unknown-linux-gnu.tar.gz"
    fi
    ;;
aarch64 | arm64)
    if ldd /bin/ls 2>&1 | grep -q musl; then
        install_tarball_from_github "astral-sh/uv" "uv-aarch64-unknown-linux-musl.tar.gz"
    else
        install_tarball_from_github "astral-sh/uv" "uv-aarch64-unknown-linux-gnu.tar.gz"
    fi
    ;;
*)
    echo "uv: unsupported arch $ARCH, skipping"
    ;;
esac

########################################################################
# Poetry
# https://python-poetry.org/docs/#installation
# Official installer with POETRY_HOME for system-wide install
########################################################################

POETRY_HOME=/usr/local
curl -sSL https://install.python-poetry.org | POETRY_HOME="$POETRY_HOME" python3 -

########################################################################
# Conda (Miniconda)
# https://docs.conda.io/projects/conda/en/latest/user-guide/install/index.html
########################################################################

CONDA_MIRROR="https://$MIRROR/anaconda/"
CONDA_PATH="/opt/conda"

case "$ARCH" in
x86_64)
    CONDA_SH="miniconda/Miniconda3-latest-Linux-x86_64.sh"
    ;;
aarch64 | arm64)
    CONDA_SH="miniconda/Miniconda3-latest-Linux-aarch64.sh"
    ;;
*)
    echo "Conda: unsupported arch $ARCH, skipping"
    CONDA_SH=""
    ;;
esac

if [ -n "${CONDA_SH:-}" ]; then
    # The installer script must end with .sh, otherwise an error will occur
    tmpfile=$(mktemp /tmp/conda.XXXXXX).sh
    curl -fSL -o "$tmpfile" "$CONDA_MIRROR$CONDA_SH"
    bash "$tmpfile" -b -p "$CONDA_PATH"
    rm -f "$tmpfile"

    export PATH="$CONDA_PATH/bin:$PATH"

    # bash, zsh — adds /etc/profile.d/conda.sh
    conda init --system --all
    # fish
    mkdir -p /etc/fish/conf.d
    ln -sf "$CONDA_PATH/etc/fish/conf.d/conda.fish" /etc/fish/conf.d/z00_conda.fish
fi
