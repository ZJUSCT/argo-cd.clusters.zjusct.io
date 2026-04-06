#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  mihomo-apply-config.sh <config.yaml>

Environment variables:
  MIHOMO_NAMESPACE     Kubernetes namespace (default: mihomo)
  MIHOMO_SECRET_NAME   Secret name for config (default: mihomo-config)
  MIHOMO_WORKLOAD      Workload to restart (default: daemonset/mihomo)
  MIHOMO_TIMEOUT       rollout status timeout (default: 5m)
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

if [ "$#" -ne 1 ]; then
    usage >&2
    exit 1
fi

CONFIG_FILE="$1"
NAMESPACE="${MIHOMO_NAMESPACE:-mihomo}"
SECRET_NAME="${MIHOMO_SECRET_NAME:-mihomo-config}"
WORKLOAD="${MIHOMO_WORKLOAD:-daemonset/mihomo}"
TIMEOUT="${MIHOMO_TIMEOUT:-5m}"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "config file not found: $CONFIG_FILE" >&2
    exit 1
fi

if [ ! -s "$CONFIG_FILE" ]; then
    echo "config file is empty: $CONFIG_FILE" >&2
    exit 1
fi

echo "Checking namespace and workload..."
kubectl get namespace "$NAMESPACE" >/dev/null
WORKLOAD_EXISTS=true
if ! kubectl -n "$NAMESPACE" get "$WORKLOAD" >/dev/null 2>&1; then
    WORKLOAD_EXISTS=false
fi

echo "Applying private Mihomo config as Secret ${NAMESPACE}/${SECRET_NAME}..."
kubectl create secret generic "$SECRET_NAME" \
    -n "$NAMESPACE" \
    --from-file=config.yaml="$CONFIG_FILE" \
    --dry-run=client \
    -o yaml | \
kubectl apply --server-side -f -

if [ "$WORKLOAD_EXISTS" != "true" ]; then
    echo "Secret applied, but ${WORKLOAD} does not exist yet. Skipping restart."
    exit 0
fi

echo "Restarting ${WORKLOAD}..."
kubectl -n "$NAMESPACE" rollout restart "$WORKLOAD"

echo "Waiting for rollout to finish..."
kubectl -n "$NAMESPACE" rollout status "$WORKLOAD" --timeout="$TIMEOUT"

echo "Mihomo config applied successfully."
