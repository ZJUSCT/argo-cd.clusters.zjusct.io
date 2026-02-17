#!/usr/bin/env bash

########################################################################
# ctld
# unknown source
########################################################################

# wget -O /tmp/ctld.deb https://gitlab.star-home.top:4430/star/deploy-ctld/-/raw/main/ctld_1.1.1_${ARCH}.deb
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
# OpenTelemtry Collector Contrib
# https://github.com/open-telemetry/opentelemetry-collector-contrib
########################################################################

# mkdir -p /etc/systemd/system/otelcol-contrib.service.d
# cat >/etc/systemd/system/otelcol-contrib.service.d/override.conf <<EOF
# [Unit]
# After=docker.service
# Requires=docker.service
# [Service]
# User=root
# Group=root
# Environment=OTEL_CLOUD_REGION=zjusct-cluster
# EOF
#
# # remember to set Environment=OTEL_BEARER_TOKEN=
# # centralized logging for otelcol
# cat >/etc/systemd/journald.conf <<EOF
# [Journal]
# Storage=volatile
# EOF

########################################################################
# dive
# https://github.com/wagoodman/dive
########################################################################

DIVE_VERSION=$(curl -sL "https://api.github.com/repos/wagoodman/dive/releases/latest" | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
curl -fOL "https://github.com/wagoodman/dive/releases/download/v${DIVE_VERSION}/dive_${DIVE_VERSION}_linux_amd64.deb"
sudo apt install ./dive_${DIVE_VERSION}_linux_amd64.deb

########################################################################
# AI Coding Assistant
# https://opencode.ai/download
# https://code.claude.com/docs/en/setup
# https://developers.openai.com/codex/quickstart
# https://geminicli.com/docs/get-started/installation/
########################################################################

npm i -g \
    opencode-ai\
    @anthropic-ai/claude-code \
    @openai/codex \
    @google/gemini-cli
