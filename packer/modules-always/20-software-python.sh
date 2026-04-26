#!/usr/bin/env bash
# shellcheck disable=SC1091
source /run/header

########################################################################
# uv
# https://docs.astral.sh/uv/getting-started/installation/#standalone-installation
########################################################################

case "$ARCH" in
x86_64) uv_arch="x86_64" ;;
aarch64 | arm64) uv_arch="aarch64" ;;
*)
    echo "uv: unsupported arch $ARCH, skipping"
    uv_arch=""
    ;;
esac

if [ -n "${uv_arch:-}" ]; then
    if [ "$MUSL" = 1 ]; then
        uv_libc="musl"
    else
        uv_libc="gnu"
    fi

    tarball=$(get_github_release_asset "astral-sh/uv" \
        "^uv-${uv_arch}-unknown-linux-${uv_libc}\\.tar\\.gz$")
    tmpdir=$(mktemp -d)
    tar xzf "$tarball" -C "$tmpdir"
    install -m 755 "$tmpdir"/uv-*/uv "$tmpdir"/uv-*/uvx /usr/local/bin/
    rm -rf "$tarball" "$tmpdir"
fi

install -D -m 0644 /dev/stdin /etc/uv/uv.toml <<EOF
[[index]]
url = "http://$MIRROR/pypi/web/simple/"
default = true
EOF

########################################################################
# Conda (Miniconda)
# https://docs.conda.io/projects/conda/en/latest/user-guide/install/index.html
########################################################################

CONDA_MIRROR="http://$MIRROR/anaconda/"
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
    bash "$tmpfile" -b -u -p "$CONDA_PATH"
    rm -f "$tmpfile"

    export PATH="$CONDA_PATH/bin:$PATH"

    # bash, zsh — adds /etc/profile.d/conda.sh
    conda init --system --all
    # fish
    mkdir -p /etc/fish/conf.d
    ln -sf "$CONDA_PATH/etc/fish/conf.d/conda.fish" /etc/fish/conf.d/z00_conda.fish
fi

install -D -m 0644 /dev/stdin "/opt/conda/.condarc" <<EOF
auto_activate_base: false
channels:
  - defaults
show_channel_urls: true
default_channels:
  - http://$MIRROR/anaconda/pkgs/main
  - http://$MIRROR/anaconda/pkgs/r
  - http://$MIRROR/anaconda/pkgs/msys2
custom_channels:
  conda-forge: http://$MIRROR/anaconda/cloud
  msys2: http://$MIRROR/anaconda/cloud
  bioconda: http://$MIRROR/anaconda/cloud
  menpo: http://$MIRROR/anaconda/cloud
  pytorch: http://$MIRROR/anaconda/cloud
  pytorch-lts: http://$MIRROR/anaconda/cloud
  simpleitk: http://$MIRROR/anaconda/cloud
  nvidia: http://$MIRROR/anaconda/cloud
EOF

conda clean -i
