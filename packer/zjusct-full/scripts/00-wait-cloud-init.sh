#!/usr/bin/env bash
set -euo pipefail

echo 'Waiting for cloud-init to complete...'

EXIT_CODE=0
cloud-init status --wait --format json || EXIT_CODE=$?

if [ ${EXIT_CODE} -ne 0 ]; then
    echo "=========================================="
    echo "cloud-init failed with exit code: ${EXIT_CODE}"
    echo "=========================================="
    echo "journalctl -u cloud-init --no-pager -n 100:"
    journalctl -u cloud-init --no-pager || true
    echo ""
    echo "=========================================="
    echo "journalctl -u cloud-init-main --no-pager -n 200:"
    journalctl -u cloud-init-main --no-pager || true
    echo ""
    echo "=========================================="
    echo "journalctl -u cloud-init-local --no-pager -n 50:"
    journalctl -u cloud-init-local --no-pager || true
    echo ""
    echo "Returning original exit code: ${EXIT_CODE}"
    exit ${EXIT_CODE}
fi

echo 'System is ready!'
