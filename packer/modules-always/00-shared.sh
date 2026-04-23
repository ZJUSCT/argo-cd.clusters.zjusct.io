#!/usr/bin/env bash
# Common functions for packer scripts

set -euo pipefail

########################################################################
# OS independent #
########################################################################
export http_proxy=http://172.28.0.4:3128
export HTTP_PROXY=http://172.28.0.4:3128
export https_proxy=http://172.28.0.4:3128
export HTTPS_PROXY=http://172.28.0.4:3128

# shellcheck disable=SC2034
MIRROR="mirrors.cernet.edu.cn"
# https://unix.stackexchange.com/questions/351557/on-what-linux-distributions-can-i-rely-on-the-presence-of-etc-os-release
# https://github.com/which-distro/os-release
# shellcheck disable=SC1091
source /etc/os-release

########################################################################
# OS specific
########################################################################
case $ID in
ubuntu | debian)
    export DEBIAN_FRONTEND=noninteractive
    ;;
esac

install_pkg() {
    case $ID in
    ubuntu | debian)
        apt-get install -y "$@"
        ;;
    fedora)
        dnf install "$@"
        ;;
    openEuler)
        dnf install "$@"
        ;;
    arch)
        pacman -S "$@"
        ;;
    *)
        echo "Unknown distribution: $ID"
        exit 1
        ;;
    esac
}

install_pkg_local() {
    case $ID in
    ubuntu | debian)
        dpkg -i "$@" || apt-get --fix-broken --fix-missing install -y
        ;;
    fedora | openEuler)
        rpm -i "$@"
        ;;
    arch)
        pacman -U "$@"
        ;;
    *)
        echo "Unknown distribution: $ID"
        exit 1
        ;;
    esac
}

########################################################################
# GitHub helpers
########################################################################

gh_release_download() {
    if ! command -v jq >/dev/null; then
        install_pkg jq
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

    [ -z "$repo" ] && { echo "gh_release_download: --repo required" >&2; return 1; }
    [ -z "$pattern" ] && { echo "gh_release_download: --pattern required" >&2; return 1; }

    mkdir -p "$dir"

    local retries=20
    while [ "$retries" -gt 0 ]; do
        local found_name="" found_url=""
        while IFS=$'\t' read -r name url; do
            case "$name" in
            "$pattern")
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

install_tarball_from_github() {
    local repo="$1"
    local pattern="$2"
    local file_pattern="${3:-}"

    local tmpdir extract_dir
    tmpdir=$(mktemp -d)
    extract_dir="$tmpdir/extract"
    mkdir -p "$extract_dir"

    gh_release_download --repo "$repo" --pattern "$pattern" --dir "$tmpdir"
    tar xzf "$tmpdir"/*.tar.gz -C "$extract_dir"

    if [ -n "$file_pattern" ]; then
        find "$extract_dir" -name "$file_pattern" -type f -exec install -m 755 {} /usr/local/bin/ \;
    else
        find "$extract_dir" -type f -executable -exec install -m 755 {} /usr/local/bin/ \;
    fi

    rm -rf "$tmpdir"
}

install_pkg_from_github() {
    local tmpdir
    tmpdir=$(mktemp -d)
    gh_release_download --repo "$1" --pattern "$2" --dir "$tmpdir"
    install_pkg_local "$tmpdir"/*
    rm -rf "$tmpdir"
}

########################################################################
# APT repo helper
########################################################################

add_repo() {
    local name="$1" key_url="$2" source="$3"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "$key_url" | gpg --dearmor -o "/etc/apt/keyrings/${name}.gpg"
    chmod 644 "/etc/apt/keyrings/${name}.gpg"
    cat >"/etc/apt/sources.list.d/${name}.list" <<EOF
$source
EOF
    apt-get update
}

########################################################################
# runtime immutable variables
########################################################################
