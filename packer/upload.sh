#!/usr/bin/env bash
set -eu

export BUCKET_NAME="packer-images"
export BUCKET_HOST="radosgw.clusters.zjusct.io"
export BUCKET_PORT="443"

: "${AWS_ACCESS_KEY_ID:?ENV AWS_ACCESS_KEY_ID is required}"
: "${AWS_SECRET_ACCESS_KEY:?ENV AWS_SECRET_ACCESS_KEY is required}"

SRC="${1:?Usage: upload.sh <file> [s3_prefix]}"
S3_PREFIX="${2:-}"

if [ ! -f "${SRC}" ]; then
    echo "ERROR: File not found: ${SRC}" >&2
    exit 1
fi

SRC_BASE="$(basename "${SRC}")"

mc alias set ceph "http://${BUCKET_HOST}:${BUCKET_PORT}" "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY"

mc cp "${SRC}" "ceph/${BUCKET_NAME}/${S3_PREFIX}${SRC_BASE}"
echo "Uploaded: s3://${BUCKET_NAME}/${S3_PREFIX}${SRC_BASE}"

mc ls "ceph/${BUCKET_NAME}/${S3_PREFIX}" | tail -n 20
