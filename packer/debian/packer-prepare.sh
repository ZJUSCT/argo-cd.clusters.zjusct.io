#!/usr/bin/env bash
set -xeou pipefail

export PACKER_LOG=1
export PACKER_LOG_PATH="packer.log"

echo "Initializing Packer plugins..."
packer init .

echo "Validating configuration..."
packer validate .
cloud-init schema -c user-data
