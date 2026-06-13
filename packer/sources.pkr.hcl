# https://developer.hashicorp.com/packer/integrations/hashicorp/qemu/latest/components/builder/qemu

packer {
  required_plugins {
    qemu = {
      version = "~> 1"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

source "qemu" "packer" {
  qemu_binary = var.qemu_binary

  # VM Configuration
  cpus             = 8
  machine_type     = var.machine_type
  cpu_model        = var.cpu_model
  accelerator      = var.accelerator
  memory           = 16384
  disk_image       = true
  # qcow2 is sparse and Packer compacts the output by default (skip_compaction=false
  # runs `qemu-img convert`), so the published file size ~= actual used space, NOT the
  # virtual disk_size. disk_size only sets the guest's virtual capacity (what cloud-init
  # growpart grows the partition to). Keep it generous: ROCm alone is ~28 GB and the full
  # GPU stack peaks ~58 GB during install; a larger value costs nothing in output size.
  disk_size        = "100G"
  iso_url          = var.iso_url
  iso_checksum     = var.iso_checksum
  format           = "qcow2"
  output_directory = "output/${var.vm_name}"
  vm_name          = "${var.vm_name}.qcow2"

  # Boot configuration
  efi_boot          = true
  efi_firmware_code = var.efi_firmware_code
  efi_firmware_vars = var.efi_firmware_vars
  boot_wait         = "10s"
  shutdown_command  = "poweroff"

  # cloud-init https://cloudinit.readthedocs.io/en/latest/reference/datasources/nocloud.html
  cd_label = "cidata"

  # Network and display
  net_device     = "virtio-net"
  disk_interface = "virtio"
  headless       = true

  # SSH Configuration
  ssh_username = "root"
  ssh_password = "packer"
  ssh_timeout  = "20m" # cross builds takes long time
}
