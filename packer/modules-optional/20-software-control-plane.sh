#!/usr/bin/env bash
# Control plane services:
# dnsmasq, haproxy, keepalived

# shellcheck disable=SC1091
source /tmp/00-shared.sh

install_pkg dnsmasq haproxy keepalived

systemctl disable --now dnsmasq
