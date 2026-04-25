#!/usr/bin/env bash
# Wait for cloud-init to complete and ensure the system is ready

# runtime immutable variables
cat >>/tmp/00-shared.sh <<EOF
ARCH="$(uname -m)"
INIT="$(ps --no-headers -o comm 1)"
EOF

# shellcheck disable=SC1091
source /tmp/00-shared.sh

if ldd /bin/ls 2>&1 | grep -q musl; then
    cat >>/tmp/00-shared.sh <<EOF
    MUSL=1
EOF
else
    cat >>/tmp/00-shared.sh <<EOF
    MUSL=0
EOF
fi

case "$ID" in
debian | ubuntu)
    cat >>/tmp/00-shared.sh <<EOF
DPKG_ARCH="$(dpkg --print-architecture)"
EOF
    ;;
esac

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
cloud-init status --wait || EXIT_CODE=$?

kill "$JOURNAL_PID" 2>/dev/null || true
wait "$JOURNAL_PID" 2>/dev/null || true

case "${EXIT_CODE}" in
# https://docs.cloud-init.io/en/latest/explanation/failure_states.html#error-codes
# 2 means recoverable error
0 | 2) ;;
*)
    echo "cloud-init failed with exit code: ${EXIT_CODE}"
    cloud-init status --format json
    exit 1
    ;;
esac



echo 'System is ready!'
