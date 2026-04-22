#!/usr/bin/env bash

cat >>common.sh <<EOF
ARCH="$(uname -m)"
EOF

# shellcheck disable=SC1091
source common.sh

########################################################################
# wait cloud-init
########################################################################

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

case "${EXIT_CODE}" in
    # https://docs.cloud-init.io/en/latest/explanation/failure_states.html#error-codes
    # 2 means recoverable error
    0|2)
        ;;
    *)
        echo "cloud-init failed with exit code: ${EXIT_CODE}"
        exit 1
        ;;
esac

echo 'System is ready!'
