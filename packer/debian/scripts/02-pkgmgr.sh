#!/usr/bin/env bash
set -xeou pipefail

########################################################################
# Python
# https://docs.astral.sh/uv/getting-started/installation/
########################################################################

pip config --site \
    set global.index-url https://mirrors.zju.edu.cn/pypi/web/simple

pip install --break-system-packages \
    uv poetry

mkdir -p /etc/uv
cat >/etc/uv/uv.toml <<EOF
[[index]]
url = "https://mirrors.zju.edu.cn/pypi/web/simple/"
default = true
EOF

########################################################################
# conda
# https://docs.conda.io/projects/conda/en/latest/user-guide/install/index.html
########################################################################

CONDA_MIRROR="https://mirrors.zju.edu.cn/anaconda/"
# Detect machine architecture via uname -m and map to installer names
MACHINE="$(uname -m)"
case "$MACHINE" in
x86_64)
    CONDA_SH="miniconda/Miniconda3-latest-Linux-x86_64.sh"
    ;;
aarch64 | arm64)
    CONDA_SH="miniconda/Miniconda3-latest-Linux-aarch64.sh"
    ;;
*)
    echo "Unsupported architecture: $MACHINE, skipping conda installation"
    CONDA_SH=""
    ;;
esac

if [ -n "$CONDA_SH" ]; then
    CONDA_PATH="/opt/conda"

    # The conda installation file must end with .sh, otherwise an error will occur, see the source code
    tmpfile=$(mktemp).sh
    if ! curl -L -o "$tmpfile" "$CONDA_MIRROR$CONDA_SH"; then
        echo "Failed to download $MIRROR$CONDA_SH"
        exit 1
    fi

    bash "$tmpfile" -b -p "$CONDA_PATH"
    rm "$tmpfile"

    export PATH="$CONDA_PATH/bin:$PATH"

    # bash, zsh
    # will add /etc/profile.d/conda.sh
    conda init --system --all
    # fish
    mkdir -p /etc/fish/conf.d
    ln -s $CONDA_PATH/etc/fish/conf.d/conda.fish /etc/fish/conf.d/z00_conda.fish

    cat >$CONDA_PATH/.condarc <<EOF
auto_activate_base: false
channels:
  - defaults
show_channel_urls: true
default_channels:
  - https://mirrors.zju.edu.cn/anaconda/pkgs/main
  - https://mirrors.zju.edu.cn/anaconda/pkgs/r
  - https://mirrors.zju.edu.cn/anaconda/pkgs/msys2
custom_channels:
  conda-forge: https://mirrors.zju.edu.cn/anaconda/cloud
  msys2: https://mirrors.zju.edu.cn/anaconda/cloud
  bioconda: https://mirrors.zju.edu.cn/anaconda/cloud
  menpo: https://mirrors.zju.edu.cn/anaconda/cloud
  pytorch: https://mirrors.zju.edu.cn/anaconda/cloud
  pytorch-lts: https://mirrors.zju.edu.cn/anaconda/cloud
  simpleitk: https://mirrors.zju.edu.cn/anaconda/cloud
  nvidia: https://mirrors.zju.edu.cn/anaconda-r
EOF

fi

########################################################################
# lmod
# https://lmod.readthedocs.io/en/latest/030_installing.html
########################################################################

# bash, zsh
# lmod package already placed lmod.sh under profile.d, so no need here
# ln -s /usr/share/lmod/lmod/init/profile /etc/profile.d/z00_lmod.sh

# fish
ln -s /usr/share/lmod/lmod/init/profile.fish /etc/fish/conf.d/z00_lmod.fish

########################################################################
# npmmirror
# https://npmmirror.com/
########################################################################

npm config set registry https://registry.npmmirror.com
cat >/etc/npmrc <<EOF
registry = "https://registry.npmmirror.com"
EOF
