#!/usr/bin/env bash
set -xeou pipefail

########################################################################
# Helper functions
########################################################################

# Mimics `gh release download` without requiring authentication.
# Usage: gh_release_download --repo OWNER/REPO --pattern GLOB [--dir DIR]
#
# Searches all releases rather than /latest so repos that ship multiple
# products on different branches are handled correctly.
gh_release_download() {
    if ! command -v jq >/dev/null; then
        echo "gh_release_download: jq is required but not installed" >&2
        return 1
    fi
    local repo="" pattern="" dir="."

    while [ $# -gt 0 ]; do
        case "$1" in
        --repo | -R)
            repo="$2"
            shift 2
            ;;
        --pattern | -p)
            pattern="$2"
            shift 2
            ;;
        --dir | -D)
            dir="$2"
            shift 2
            ;;
        *)
            echo "gh_release_download: unknown option: $1" >&2
            return 1
            ;;
        esac
    done

    [ -z "$repo" ] && {
        echo "gh_release_download: --repo required" >&2
        return 1
    }
    [ -z "$pattern" ] && {
        echo "gh_release_download: --pattern required" >&2
        return 1
    }

    mkdir -p "$dir"

    local retries=20
    while [ "$retries" -gt 0 ]; do
        local found_name="" found_url=""
        while IFS=$'\t' read -r name url; do
            # shellcheck disable=SC2254
            case "$name" in
            $pattern)
                found_name="$name"
                found_url="$url"
                break
                ;;
            esac
        done < <(curl -sSf "https://api.github.com/repos/$repo/releases" |
            jq -r '.[].assets[] | [.name, .browser_download_url] | @tsv')

        if [ -n "$found_url" ]; then
            if curl -fSL -o "$dir/$found_name" "$found_url"; then
                echo "Downloaded: $dir/$found_name"
                return 0
            fi
            echo "Download failed, retrying..." >&2
        fi

        retries=$((retries - 1))
        sleep 1
    done

    echo "gh_release_download: no asset matching '$pattern' in $repo" >&2
    return 1
}

# install_pkg_from_github OWNER/REPO GLOB_PATTERN
# Example: install_pkg_from_github wagoodman/dive "dive_*_linux_amd64.deb"
install_pkg_from_github() {
    local tmpdir
    tmpdir=$(mktemp -d)
    gh_release_download --repo "$1" --pattern "$2" --dir "$tmpdir"
    dpkg -i "$tmpdir"/*.deb || apt-get --fix-broken --fix-missing install -y
    rm -rf "$tmpdir"
}

# install_bin_from_github OWNER/REPO GLOB_PATTERN [DEST_NAME]
# Downloads a single binary asset and installs it to /usr/local/bin.
# If DEST_NAME is omitted the downloaded filename is used as-is.
install_bin_from_github() {
    local tmpdir
    tmpdir=$(mktemp -d)
    gh_release_download --repo "$1" --pattern "$2" --dir "$tmpdir"
    if [ -n "${3:-}" ]; then
        install -m 755 "$tmpdir"/* "/usr/local/bin/$3"
    else
        install -m 755 "$tmpdir"/* /usr/local/bin/
    fi
    rm -rf "$tmpdir"
}

# install_tarball_from_github OWNER/REPO TARBALL_PATTERN [FILE_PATTERN]
# Downloads a .tar.gz asset, extracts it, and installs files to /usr/local/bin.
# - By default, only executable files are installed.
# - If FILE_PATTERN is provided, only files matching that pattern are installed.
install_tarball_from_github() {
    local repo="$1"
    local pattern="$2"
    local file_pattern="${3:-}"

    local tmpdir extract_dir
    tmpdir=$(mktemp -d)
    extract_dir="$tmpdir/extract"
    mkdir -p "$extract_dir"

    gh_release_download --repo "$repo" --pattern "$pattern" --dir "$tmpdir"

    # Extract to subdirectory
    tar xzvf "$tmpdir"/*.tar.gz -C "$extract_dir"

    # Install files based on pattern
    if [ -n "$file_pattern" ]; then
        # Install files matching the specified pattern
        find "$extract_dir" -name "$file_pattern" -type f -exec install -m 755 {} /usr/local/bin/ \;
    else
        # Default: only install executable files
        find "$extract_dir" -type f -executable -exec install -m 755 {} /usr/local/bin/ \;
    fi

    rm -rf "$tmpdir"
}

########################################################################
# ctld
# unknown source
########################################################################

# wget -O /tmp/ctld.deb https://gitlab.star-home.top:4430/star/deploy-ctld/-/raw/main/ctld_1.1.1_amd64.deb
# dpkg -i /tmp/ctld.deb
# cat <<EOF >/etc/systemd/system/ctld.service
# [Unit]
# Description=Control Daemon
# After=network.target
#
# [Service]
# Type=simple
# ExecStart=/usr/bin/ctld client -server 172.25.4.11:4320
# Restart=always
# RestartSec=5
#
# [Install]
# WantedBy=multi-user.target
# EOF

########################################################################
# Containers
########################################################################

# https://github.com/wagoodman/dive
install_pkg_from_github "wagoodman/dive" "dive_*_linux_amd64.deb"

# https://github.com/apptainer/apptainer
install_pkg_from_github "apptainer/apptainer" "apptainer_*_amd64.deb"

########################################################################
# AI Coding Assistant
# https://code.claude.com/docs/en/setup
########################################################################

# https://github.com/anomalyco/opencode
case "$(uname -m)" in
x86_64)
    install_tarball_from_github "anomalyco/opencode" "opencode-linux-x64-musl.tar.gz"
    ;;
aarch64 | arm64)
    install_tarball_from_github "anomalyco/opencode" "opencode-linux-arm64-musl.tar.gz"
    ;;
esac

# https://github.com/openai/codex
# Binary is extracted as codex-{arch}-unknown-linux-gnu, so we rename to "codex".
codex_tmpdir=$(mktemp -d)
case "$(uname -m)" in
x86_64)   codex_arch="x86_64" ;;
aarch64 | arm64) codex_arch="aarch64" ;;
esac
if [ -n "${codex_arch:-}" ]; then
    gh_release_download --repo "openai/codex" \
        --pattern "codex-${codex_arch}-unknown-linux-gnu.tar.gz" --dir "$codex_tmpdir"
    tar xzvf "$codex_tmpdir"/*.tar.gz -C "$codex_tmpdir"
    rm "$codex_tmpdir"/*.tar.gz
    install -m 755 "$codex_tmpdir"/codex-* /usr/local/bin/codex
fi
rm -rf "$codex_tmpdir"

########################################################################
# Python
# https://docs.astral.sh/uv/getting-started/installation/
########################################################################

pip config --global \
    set global.index-url https://mirrors.zju.edu.cn/pypi/web/simple

pip install --break-system-packages \
    uv poetry

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
fi
