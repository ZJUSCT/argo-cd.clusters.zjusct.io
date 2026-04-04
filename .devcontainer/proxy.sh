#!/bin/sh
# proxy.sh - Detect and export proxy environment variables
# Install to /etc/profile.d/ so every login shell picks it up.

PROXY_URL="${PROXY_URL:-http://172.28.0.4:3128}"
NO_PROXY="${NO_PROXY:-localhost,zjusct.io}"

if curl -x "$PROXY_URL" -sf --connect-timeout 2 http://mirrors.zju.edu.cn >/dev/null 2>&1; then
    export http_proxy="$PROXY_URL" https_proxy="$PROXY_URL"
    export HTTP_PROXY="$PROXY_URL" HTTPS_PROXY="$PROXY_URL"
    export no_proxy="$NO_PROXY" NO_PROXY="$NO_PROXY"
fi
