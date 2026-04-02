#!/usr/bin/env bash
set -euo pipefail

echo 'Waiting for cloud-init to complete...'

# Stream cloud-init logs in real-time, kill when cloud-init finishes
journalctl \
    -u cloud-init-local \
    -u cloud-init-network \
    -u cloud-init-main \
    -u cloud-config \
    -f --no-pager &
JOURNAL_PID=$!

EXIT_CODE=0
cloud-init status --wait --format json || EXIT_CODE=$?

kill "$JOURNAL_PID" 2>/dev/null || true
wait "$JOURNAL_PID" 2>/dev/null || true

if [ "${EXIT_CODE}" -ne 0 ]; then
    echo "=========================================="
    echo "cloud-init failed with exit code: ${EXIT_CODE}"
    echo "=========================================="
    echo "Returning original exit code: ${EXIT_CODE}"
    exit "${EXIT_CODE}"
fi

echo 'System is ready!'
