#!/usr/bin/env bash
export BUCKET_NAME="packer-images"
export BUCKET_HOST="radosgw.clusters.zjusct.io"
export BUCKET_PORT="443"
export AWS_ACCESS_KEY_ID=""
export AWS_SECRET_ACCESS_KEY=""

s3cmd put ./debian-13-generic-amd64-20250911-2232.qcow2 \
    "s3://${BUCKET_NAME}/debian/" \
    --access_key="$AWS_ACCESS_KEY_ID" \
    --secret_key="$AWS_SECRET_ACCESS_KEY" \
    --host="${BUCKET_HOST}:${BUCKET_PORT}" \
    --host-bucket="${BUCKET_HOST}:${BUCKET_PORT}" \
    --no-check-certificate
