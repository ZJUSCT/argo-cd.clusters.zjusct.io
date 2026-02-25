# FreeIPA

## Enrollment

1. Unprovision on WebUI. Set OTP.
2. Enroll

```bash
ipa-client-install \
    --domain clusters.zjusct.io \
    --unattended \
    --automount-location=default \
    --no-ntp \
    --force-join \
    --no-dns-sshfp \
    --password $(IPA_ENROLL_PASSWORD)
```

Sometimes `--hostname` is needed.
