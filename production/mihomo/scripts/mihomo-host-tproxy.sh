#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  mihomo-host-tproxy.sh up
  mihomo-host-tproxy.sh down
  mihomo-host-tproxy.sh status

Environment variables:
  MIHOMO_TPROXY_VIP      TPROXY VIP address (default: 172.25.4.1)
  MIHOMO_TPROXY_PORT     Mihomo tproxy port (default: 7892)
  MIHOMO_FAKE_IP_CIDR    Fake-IP CIDR (default: 11.255.0.0/16)
  MIHOMO_TPROXY_FWMARK   Firewall mark value (default: 1)
  MIHOMO_TPROXY_TABLE    Policy routing table id (default: 100)
  MIHOMO_NFT_TABLE       nftables table name (default: mihomo_tproxy)
EOF
}

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "required command not found: $1" >&2
        exit 1
    fi
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

if [ "$#" -ne 1 ]; then
    usage >&2
    exit 1
fi

ACTION="$1"
MIHOMO_TPROXY_VIP="${MIHOMO_TPROXY_VIP:-172.25.4.1}"
MIHOMO_TPROXY_PORT="${MIHOMO_TPROXY_PORT:-7892}"
MIHOMO_FAKE_IP_CIDR="${MIHOMO_FAKE_IP_CIDR:-11.255.0.0/16}"
MIHOMO_TPROXY_FWMARK="${MIHOMO_TPROXY_FWMARK:-1}"
MIHOMO_TPROXY_TABLE="${MIHOMO_TPROXY_TABLE:-100}"
MIHOMO_NFT_TABLE="${MIHOMO_NFT_TABLE:-mihomo_tproxy}"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    exec sudo --preserve-env=MIHOMO_TPROXY_VIP,MIHOMO_TPROXY_PORT,MIHOMO_FAKE_IP_CIDR,MIHOMO_TPROXY_FWMARK,MIHOMO_TPROXY_TABLE,MIHOMO_NFT_TABLE "$0" "$@"
fi

require_cmd ip
require_cmd nft

rule_present() {
    local mark_hex
    printf -v mark_hex '%x' "$MIHOMO_TPROXY_FWMARK"
    ip -4 rule show | grep -Eq "fwmark 0x${mark_hex} .* lookup ${MIHOMO_TPROXY_TABLE}"
}

apply_nft() {
    nft delete table inet "$MIHOMO_NFT_TABLE" 2>/dev/null || true
    nft -f - <<EOF
table inet ${MIHOMO_NFT_TABLE} {
    set fake_ip_v4 {
        type ipv4_addr
        flags interval
        elements = {
            ${MIHOMO_FAKE_IP_CIDR}
        }
    }

    chain prerouting_tproxy {
        type filter hook prerouting priority mangle; policy accept;
        ct direction reply counter return
        meta l4proto { tcp, udp } ip daddr @fake_ip_v4 meta mark set ${MIHOMO_TPROXY_FWMARK} tproxy ip to ${MIHOMO_TPROXY_VIP}:${MIHOMO_TPROXY_PORT} counter accept
    }

    chain output_tproxy {
        type route hook output priority mangle; policy accept;
        ct direction reply counter return
        meta l4proto { tcp, udp } ip daddr @fake_ip_v4 meta mark set ${MIHOMO_TPROXY_FWMARK} counter accept
    }
}
EOF
}

apply_routing() {
    if ! rule_present; then
        ip -4 rule add fwmark "$MIHOMO_TPROXY_FWMARK" lookup "$MIHOMO_TPROXY_TABLE"
    fi
    ip -4 route replace local 0.0.0.0/0 dev lo table "$MIHOMO_TPROXY_TABLE"
}

remove_routing() {
    while rule_present; do
        ip -4 rule del fwmark "$MIHOMO_TPROXY_FWMARK" lookup "$MIHOMO_TPROXY_TABLE" 2>/dev/null || true
    done
    ip -4 route del local 0.0.0.0/0 dev lo table "$MIHOMO_TPROXY_TABLE" 2>/dev/null || true
}

show_status() {
    echo "== ip rule =="
    ip -4 rule show
    echo
    echo "== table ${MIHOMO_TPROXY_TABLE} =="
    ip -4 route show table "$MIHOMO_TPROXY_TABLE" 2>/dev/null || true
    echo
    echo "== nft table inet ${MIHOMO_NFT_TABLE} =="
    nft list table inet "$MIHOMO_NFT_TABLE" 2>/dev/null || echo "table inet ${MIHOMO_NFT_TABLE} not found"
}

case "$ACTION" in
up)
    apply_nft
    apply_routing
    show_status
    ;;
down)
    nft delete table inet "$MIHOMO_NFT_TABLE" 2>/dev/null || true
    remove_routing
    show_status
    ;;
status)
    show_status
    ;;
*)
    usage >&2
    exit 1
    ;;
esac
