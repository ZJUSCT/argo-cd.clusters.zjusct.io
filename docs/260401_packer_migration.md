## Migration: Split Debian Image Build into zjusct-base + zjusct-full

### Status: Migration code complete, local build pending

### What was done

The monolithic `packer/debian/` (deleted) was split into two independent image builds:

- **`packer/zjusct-base/`** — Standalone HPC competition node (simple, no cluster tools)
  - Single Packer build producing `output/zjusct-base.qcow2`
  - Source: Debian 13 cloud image from mirrors.cernet.edu.cn
  - Installs: dev tools, Docker, NVIDIA (drivers + CUDA + DOCA), NFS, Python, npm, AI coding assistants, conda, lmod
  - Removed: domain control (freeipa-client, sssd-*, ldap-utils, autofs), K8S (kubectl, kubelet, kubeadm), ceph-common, otelcol-contrib, K8S CLI tools (argocd, cilium, hubble, kubeseal, kustomize, virtctl, helm), cephtrace
  - Removed 4 rootfs files: `docker.socket.d/override.conf`, `sssd.service.d/override.conf`, `otelcol-contrib.service.d/override.conf`, `otelcol-contrib/config.yaml`
  - Replaced `packer-cloud-init.sh` + `packer-customize.sh` with single `packer-build.sh`

- **`packer/zjusct-full/`** — Campus cluster node (builds on top of zjusct-base)
  - Single Packer build producing `output/zjusct-full.qcow2`
  - Source: `debian/zjusct-base.qcow2` from RGW (`http://rook-ceph-rgw-ceph-objectstore.rook-ceph.svc/packer-images/debian/zjusct-base.qcow2`)
  - Its own `user-data`: only installs domain control + K8S + ceph packages via cloud-init
  - `scripts/01-software.sh`: K8S CLI tools, otelcol-contrib, cephtrace
  - `scripts/02-config.sh`: SSSD/otelcol/docker.socket overrides, SSSD socket disable, kubelet disable, `groupdel docker`
  - `rootfs/`: only the 4 cluster-specific config files
  - Fixed bug from original: sssd override was being installed to wrong path (`/etc/systemd/systemd/otelcol-contrib.service.d/override.conf` → `/etc/systemd/system/sssd.service.d/override.conf`)

### Tekton PipelineRuns

- **Removed**: `packer-debian-cloud-init-run.yaml`, `packer-debian-customize-run.yaml`
- **Added**: `packer-zjusct-base-run.yaml` (uploads `debian/zjusct-base.qcow2`), `packer-zjusct-full-run.yaml` (uploads `debian/zjusct-full.qcow2`)

### Devcontainer changes

- **Dockerfile**: Added `qemu-system-x86`, `qemu-utils`, `ovmf`, `cloud-init`, `cloud-image-utils` packages + OVMF symlinks
- **compose.yaml**: Added `privileged: true` for KVM access; `network_mode: host` commented out by user

### Next step: Build zjusct-base locally

After devcontainer rebuild, run:

```bash
cd /workspace/packer/zjusct-base
rm -rf output  # clean any stale output dir
bash packer-build.sh
```

If the build succeeds, verify the output:

```bash
ls -lh output/zjusct-base.qcow2
qemu-img info output/zjusct-base.qcow2
```

Then optionally build zjusct-full (requires zjusct-base.qcow2 uploaded to RGW first, or test with a local file by temporarily changing the `iso_url` in `packer/zjusct-full/build.pkr.hcl`).
