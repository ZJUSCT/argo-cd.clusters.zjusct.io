# Simplest Packer Ubuntu Configuration

This is a minimal, fully self-contained Packer configuration for building an Ubuntu image with **no external dependencies, variables, or variants**.

## What This Does

- Downloads Ubuntu 22.04 LTS (Jammy) cloud image
- Boots it with cloud-init configuration
- Updates the system
- Installs basic packages (curl, wget, vim)
- Cleans up and prepares for deployment
- Outputs a QCOW2 image ready to use

## Prerequisites

**Option 1: Using Docker (Recommended - No Packer installation needed!)**

- Only **Docker** is required
- Packer runs inside a container

**Option 2: Native Installation**

- **Packer** (v1.7.0 or newer)
- **QEMU/KVM** (for virtualization)

## Usage

### Quick Start with Docker (No Packer Installation Required)

Simply run the provided script:

```bash
./build.sh
```

This will automatically:

- Pull the Packer Docker image
- Initialize plugins
- Validate the configuration
- Build the image

**Manual Docker commands:**

```bash
# Initialize Packer plugins
sudo docker run --rm \
  -v "$PWD:/workspace" \
  -v "$HOME/.packer.d:/root/.config/packer" \
  -w /workspace \
  hashicorp/packer:latest init ubuntu-simple.pkr.hcl

# Validate the configuration
sudo docker run --rm \
  -v "$PWD:/workspace" \
  -v "$HOME/.packer.d:/root/.config/packer" \
  -w /workspace \
  hashicorp/packer:latest validate ubuntu-simple.pkr.hcl

# Build the image (requires --privileged for KVM)
sudo docker run --rm --privileged \
  -v "$PWD:/workspace" \
  -v "$HOME/.packer.d:/root/.config/packer" \
  -v /dev:/dev \
  -w /workspace \
  hashicorp/packer:latest build ubuntu-simple.pkr.hcl
```

### Alternative: Native Packer Installation

If you prefer to install Packer natively:

```bash
# Install QEMU/KVM on Ubuntu/Debian
sudo apt-get update
sudo apt-get install -y qemu-kvm qemu-utils

# Install Packer from https://www.packer.io/downloads

# Then run:
packer init ubuntu-simple.pkr.hcl
packer validate ubuntu-simple.pkr.hcl
packer build ubuntu-simple.pkr.hcl
```

The build will:

- Download the Ubuntu cloud image (~700MB)
- Boot a VM with cloud-init
- Run provisioning scripts
- Take approximately 10-15 minutes
- Output image to `output/ubuntu-simple.qcow2`

## Output

The final image will be in:

```
output/ubuntu-simple.qcow2
```

You can then use this image with:

- QEMU/KVM
- libvirt
- OpenStack
- Any other platform that supports QCOW2 images

## Test the Image

```bash
qemu-system-x86_64 \
  -machine accel=kvm \
  -cpu host \
  -m 2048 \
  -drive file=output/ubuntu-simple.qcow2,if=virtio \
  -net nic,model=virtio \
  -net user \
  -nographic
```

## Customization

All configuration is in a single file: `ubuntu-simple.pkr.hcl`

To customize:

- Change Ubuntu version: modify `iso_url` and `iso_checksum`
- Add packages: edit the "Install additional packages" provisioner
- Change VM specs: modify `cpus`, `memory`, `disk_size`
- Add custom scripts: add more `provisioner "shell"` blocks

## Differences from Original Repo

The original packer-maas repo has:

- ✗ Multiple variable files
- ✗ External shell scripts
- ✗ MAAS-specific curtin hooks
- ✗ Complex post-processing with NBD/FUSE
- ✗ Support for multiple architectures and variants
- ✗ Custom tar.gz packaging

This simplified version has:

- ✓ Single self-contained HCL file
- ✓ All configuration inline
- ✓ Simple QCOW2 output
- ✓ No external dependencies
- ✓ Minimal cloud-init setup
- ✓ Easy to understand and modify

## Files

- `ubuntu-simple.pkr.hcl` - Main Packer configuration (everything in one file)
- `user-data` - Cloud-init user configuration
- `meta-data` - Cloud-init metadata
- `build.sh` - Automated build script using Docker (optional)
- `README.md` - This file

Total: 5 files, no external dependencies!
