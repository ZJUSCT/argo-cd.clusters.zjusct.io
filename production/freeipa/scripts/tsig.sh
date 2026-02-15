#!/bin/bash
# Script to generate RFC2136 TSIG key for external-dns from FreeIPA
# Reference: https://blog.davy.tw/posts/automatically-sign-certificate-using-cert-manager-and-freeipa/

set -euo pipefail

NAMESPACE="freeipa"
POD_NAME="ipa-01-0"
KEY_NAME="external-dns-update"
ZONE="clusters.zjusct.io"
SECRET_NAME="rfc2136-keys"
OUTPUT_FILE="../resources/rfc2136-sealedsecret.yaml"

# FreeIPA credentials - can be overridden via environment variables
IPA_USER="${IPA_USER:-admin}"
IPA_PASSWORD="${IPA_PASSWORD:-}"

echo "Generating TSIG key in FreeIPA pod..."

# Check if the TSIG key already exists in the pod
EXISTING_KEY=$(kubectl -n "$NAMESPACE" exec "$POD_NAME" -- bash -c "grep -A3 'key \"$KEY_NAME\"' /etc/named/ipa-ext.conf 2>/dev/null || true")

if [ -n "$EXISTING_KEY" ]; then
    echo "TSIG key '$KEY_NAME' already exists. Extracting..."
    TSIG_SECRET=$(echo "$EXISTING_KEY" | grep -oP 'secret "\K[^"]+' || true)
else
    echo "Generating new TSIG key '$KEY_NAME'..."

    # Generate the TSIG key and append to configuration
    kubectl -n "$NAMESPACE" exec "$POD_NAME" -- bash -c "tsig-keygen -a hmac-sha512 '$KEY_NAME' >> /etc/named/ipa-ext.conf"

    # Reload named configuration
    kubectl -n "$NAMESPACE" exec "$POD_NAME" -- rndc reload

    # Extract the secret from the newly generated key
    TSIG_SECRET=$(kubectl -n "$NAMESPACE" exec "$POD_NAME" -- bash -c "grep -A1 'key \"$KEY_NAME\"' /etc/named/ipa-ext.conf | grep -oP 'secret \"\K[^\"]+'" || true)

    # Configure DNS zone for dynamic updates
    echo "Configuring DNS zone for dynamic updates..."
    # Note: This requires Kerberos authentication. If it fails, you may need to run it manually:
    # kubectl -n freeipa exec -it ipa-01-0 -- bash
    # kinit admin
    # ipa dnszone-mod clusters.zjusct.io --dynamic-update=True --update-policy='grant external-dns-update wildcard * ANY;'

    if [ -z "$IPA_PASSWORD" ]; then
        echo "WARNING: IPA_PASSWORD not set. Attempting to read from Kubernetes secret..."
        IPA_PASSWORD=$(kubectl -n "$NAMESPACE" get secret freeipa-admin-secrets -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d || true)
    fi

    if [ -n "$IPA_PASSWORD" ]; then
        if ! kubectl -n "$NAMESPACE" exec "$POD_NAME" -- bash -c "echo '$IPA_PASSWORD' | kinit '$IPA_USER' && ipa dnszone-mod '$ZONE' --dynamic-update=True --update-policy='grant $KEY_NAME wildcard * ANY;'"; then
            echo "WARNING: Failed to configure DNS zone. You may need to configure it manually."
            echo "Run: ipa dnszone-mod $ZONE --dynamic-update=True --update-policy='grant $KEY_NAME wildcard * ANY;'"
        fi
    else
        echo "WARNING: IPA_PASSWORD not available. Skipping DNS zone configuration."
        echo "You may need to configure it manually:"
        echo "  kubectl -n freeipa exec -it ipa-01-0 -- bash"
        echo "  kinit $IPA_USER"
        echo "  ipa dnszone-mod $ZONE --dynamic-update=True --update-policy='grant $KEY_NAME wildcard * ANY;'"
    fi
fi

# Enable AXFR (zone transfer) for the TSIG key
# This is required for external-dns sync policy to work properly
# Note: FreeIPA's 'ipa dnszone-mod --allow-transfer' doesn't support TSIG keys,
# so we use ldapmodify directly to set the idnsAllowTransfer attribute
echo "Enabling AXFR for TSIG key..."

# Get LDAP suffix from FreeIPA realm
LDAP_SUFFIX=$(kubectl -n "$NAMESPACE" exec "$POD_NAME" -- bash -c "cat /etc/ipa/default.conf | grep -oP 'basedn = \K.*' | tr ',' '/' | sed 's/dc=/dc=/g'" 2>/dev/null || echo "dc=clusters,dc=zjusct,dc=io")
LDAP_DN="idnsname=$ZONE.,cn=dns,$LDAP_SUFFIX"

if [ -n "$IPA_PASSWORD" ]; then
    if ! kubectl -n "$NAMESPACE" exec "$POD_NAME" -- bash -c "echo '$IPA_PASSWORD' | kinit '$IPA_USER' && ldapmodify -Y EXTERNAL -H ldapi://%2fvar%2frun%2fslapd-CLUSTERS-ZJUSCT-IO.socket <<< \"dn: $LDAP_DN
changetype: modify
replace: idnsAllowTransfer
idnsAllowTransfer: key $KEY_NAME
\""; then
        echo "WARNING: Failed to enable AXFR. You may need to configure it manually."
        echo "Run in FreeIPA pod:"
        echo "  kinit admin"
        echo "  ldapmodify -Y EXTERNAL -H ldapi://%2fvar%2frun%2fslapd-CLUSTERS-ZJUSCT-IO.socket"
        echo "  dn: $LDAP_DN"
        echo "  changetype: modify"
        echo "  replace: idnsAllowTransfer"
        echo "  idnsAllowTransfer: key $KEY_NAME"
    else
        echo "AXFR enabled for key '$KEY_NAME' on zone '$ZONE'"
    fi
else
    echo "WARNING: IPA_PASSWORD not available. Skipping AXFR configuration."
    echo "To enable AXFR manually, run in FreeIPA pod:"
    echo "  kinit admin"
    echo "  ldapmodify -Y EXTERNAL -H ldapi://%2fvar%2frun%2fslapd-CLUSTERS-ZJUSCT-IO.socket"
    echo "  dn: $LDAP_DN"
    echo "  changetype: modify"
    echo "  replace: idnsAllowTransfer"
    echo "  idnsAllowTransfer: key $KEY_NAME"
fi

if [ -z "$TSIG_SECRET" ]; then
    echo "ERROR: Failed to extract TSIG secret"
    exit 1
fi

echo "TSIG Key Name: $KEY_NAME"
echo "TSIG Secret: ${TSIG_SECRET:0:20}... (truncated for security)"

# Create a temporary secret manifest
TEMP_SECRET=$(mktemp)
trap 'rm -f $TEMP_SECRET' EXIT

cat > "$TEMP_SECRET" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: $SECRET_NAME
  namespace: $NAMESPACE
type: Opaque
stringData:
  rfc2136-tsig-keyname: "$KEY_NAME"
  rfc2136-tsig-secret: "$TSIG_SECRET"
EOF

echo "Creating SealedSecret..."

# Generate the SealedSecret using kubeseal
kubeseal --format=yaml < "$TEMP_SECRET" > "$OUTPUT_FILE"

echo "SealedSecret created at: $OUTPUT_FILE"
echo ""
echo "Next steps:"
echo "1. Uncomment the valuesFile line in kustomization.yaml"
echo "2. Add the SealedSecret to kustomization.yaml resources"
echo "3. Commit and push the changes"
echo "4. ArgoCD will deploy external-dns with RFC2136 support"
