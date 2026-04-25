#!/usr/bin/env bash
# Common functions for packer scripts
# This script should only contain declarations and should not have side effects when sourced

set -xeuo pipefail

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
# Command wrappers
########################################################################
curl() {
    command curl --retry 20 --retry-all-errors --retry-connrefused --location --silent --show-error --fail "$@"
}

systemctl() {
    if [ "$INIT" = "systemd" ]; then
        command systemctl "$@"
    else
        # Skip systemctl commands on container environments
        # for module testing
        echo "systemctl $* (skipped)"
    fi
}

########################################################################
# OS specific
########################################################################
install_pkg() {
    case $ID in
    ubuntu | debian)
        apt-get install -y -o DPkg::Lock::Timeout=600 "$@"
        ;;
    fedora | rocky)
        dnf install -y "$@"
        ;;
    arch)
        pacman -S --noconfirm "$@"
        ;;
    *)
        echo "Unknown distribution: $ID"
        exit 1
        ;;
    esac
}

uninstall_pkg() {
    case $ID in
    ubuntu | debian)
        apt-get purge -y "$@"
        apt-get autoremove -y
        ;;
    fedora | rocky)
        dnf remove -y "$@"
        ;;
    arch)
        pacman -Rns "$@"
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

# get_github_release_asset <repo> <pattern>
#   Input:  repo    - GitHub repository (e.g. cli/cli)
#           pattern - Oniguruma regex to match asset name (e.g. "gh_.*_linux_amd64\\.tar\\.gz")
#   Output: prints the path of the downloaded file in /tmp
#   Errors: returns 1 if no match, multiple matches, download failed, or digest mismatch
get_github_release_asset() {
    local repo="$1" pattern="$2"
    local result
    result=$(curl \
        "https://api.github.com/repos/$repo/releases/latest" |
        jq -r --arg re "$pattern" '
            [ .assets[] | select(.name | test($re)) | {name, browser_download_url, digest} ] |
            if length == 0 then error("no asset matching \($re)")
            elif length > 1 then error("multiple assets matching \($re): " + ([.[].name] | join(", ")))
            else .[0] | "\(.name)\t\(.browser_download_url)\t\(.digest)"
            end
        ') || {
        echo "get_github_release_asset: $result" >&2
        return 1
    }

    local name url expected_digest filepath
    IFS=$'\t' read -r name url expected_digest <<<"$result"
    filepath="/tmp/$name"

    curl \
        --output "$filepath" "$url" || {
        echo "get_github_release_asset: download failed for $name" >&2
        return 1
    }

    local algo="${expected_digest%%:*}"
    local hash="${expected_digest#*:}"
    echo "$hash  $filepath" | "${algo}sum" --check --quiet || {
        echo "get_github_release_asset: $algo digest mismatch for $name" >&2
        return 1
    }

    echo "$filepath"
}

########################################################################
# APT repo helper
########################################################################

add_repo() {
    case $ID in
    ubuntu | debian)
        local name="$1" key_url="$2" source="$3"
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL "$key_url" | gpg --dearmor -o "/etc/apt/keyrings/${name}.gpg"
        chmod 644 "/etc/apt/keyrings/${name}.gpg"
        cat >"/etc/apt/sources.list.d/${name}.list" <<EOF
deb [signed-by=/etc/apt/keyrings/${name}.gpg] $source
EOF
        apt-get update
        ;;
    fedora | rocky)
        dnf config-manager --add-repo "$1"
        ;;
    *)
        echo "add_repo: unsupported distro: $ID" >&2
        return 1
        ;;
    esac
}

########################################################################
# runtime immutable variables
########################################################################
