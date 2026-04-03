#!/usr/bin/env bash
set -xeuo pipefail

apt-get install -y doca-all || true

KVER="$(uname -r)"
MFT_VER="$(dkms status kernel-mft-dkms 2>/dev/null | head -1 | grep -oP 'kernel-mft-dkms/\K[^,]+' || true)"

echo "=== Fixing doca-all / kernel-mft-dkms installation ==="
echo "Kernel: $KVER"
echo "MFT version: $MFT_VER"

# Step 1: Remove conflicting unversioned modules
MOD_DIR="/lib/modules/${KVER}/updates/dkms"
echo ""
echo "=== Step 1: Removing conflicting unversioned modules ==="
for mod in mst_pci.ko.xz mst_pciconf.ko.xz; do
    if [ -f "${MOD_DIR}/${mod}" ]; then
        echo "Removing ${MOD_DIR}/${mod}"
        rm -f "${MOD_DIR}/${mod}"
    else
        echo "${mod} not found (already removed)"
    fi
done

# Step 2: Remove the failed DKMS state so we can retry cleanly
echo ""
echo "=== Step 2: Cleaning DKMS state for kernel-mft-dkms ==="
dkms remove kernel-mft-dkms/"${MFT_VER}" --all 2>/dev/null || true

# Step 3: Re-add and build/install with --force
echo ""
echo "=== Step 3: Rebuilding kernel-mft-dkms ==="
dkms add kernel-mft-dkms/"${MFT_VER}" 2>/dev/null || true
dkms build kernel-mft-dkms/"${MFT_VER}" -k "${KVER}"
dkms install kernel-mft-dkms/"${MFT_VER}" -k "${KVER}" --force

# Step 4: Reconfigure the stuck dpkg packages
echo ""
echo "=== Step 4: Reconfiguring dpkg packages ==="
dpkg --configure -a

# Step 5: Verify
echo ""
echo "=== Step 5: Verifying installation ==="
if dkms status kernel-mft-dkms 2>/dev/null | grep -q "installed"; then
    echo "SUCCESS: kernel-mft-dkms is installed."
else
    echo "WARNING: kernel-mft-dkms may not be fully installed. Check 'dkms status'."
fi

if dpkg -l linux-headers-6.12.74+deb13+1-amd64 2>/dev/null | grep -q '^ii'; then
    echo "SUCCESS: linux-headers package is configured."
else
    echo "WARNING: linux-headers package may still have issues."
fi

echo ""
echo "=== Done ==="
