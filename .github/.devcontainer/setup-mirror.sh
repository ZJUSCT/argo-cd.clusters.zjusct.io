#!/usr/bin/env bash
set -euo pipefail

MIRROR="${MIRROR:-mirrors.cernet.edu.cn}"
DEBIAN_MIRROR="http://${MIRROR}"
DOCKER_MIRROR="http://${MIRROR}/docker-ce/linux/debian"
PYPI_MIRROR="http://${MIRROR}/pypi/web/simple"
NPM_REGISTRY="http://registry.npmmirror.com/"

# shellcheck disable=SC1091
. /etc/os-release

if [ "${ID:-}" != "debian" ]; then
    echo "setup-mirror.sh only supports Debian-based devcontainer images" >&2
    exit 1
fi

find /etc/apt -type f \( -name '*.list' -o -name '*.sources' \) \
    -exec sed -i \
        -e "s|https\?://deb.debian.org|${DEBIAN_MIRROR}|g" \
        -e "s|https\?://security.debian.org|${DEBIAN_MIRROR}|g" \
        -e "s|https\?://download.docker.com/linux/debian|${DOCKER_MIRROR}|g" \
        {} +

cat >/etc/pip.conf <<EOF
[global]
index-url = ${PYPI_MIRROR}
trusted-host = ${MIRROR}
EOF

install -d -m 0755 /etc/uv
cat >/etc/uv/uv.toml <<EOF
[[index]]
url = "${PYPI_MIRROR}/"
default = true
EOF

cat >/etc/npmrc <<EOF
registry=${NPM_REGISTRY}
EOF
