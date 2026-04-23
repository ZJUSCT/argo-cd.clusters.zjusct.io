# https://developer.hashicorp.com/packer/integrations/hashicorp/qemu/latest/components/builder/qemu

locals {
  qemu_arch = {
    "x86_64"  = "x86_64"
    "arm64"   = "aarch64"
    "riscv64" = "riscv64"
  }
  machine_type = {
    "x86_64"  = "pc"
    "arm64"   = "virt"
    "riscv64" = "virt"
  }
  can_kvm = var.host_arch == var.arch
  efi_firmware_code = {
    "x86_64"  = "/usr/share/OVMF/OVMF_CODE_4M.fd"
    "arm64"   = "/usr/share/AAVMF/AAVMF_CODE.fd"
    "riscv64" = "/usr/share/qemu-efi-riscv64/RISCV_VIRT_CODE.fd"
  }
  efi_firmware_vars = {
    "x86_64"  = "/usr/share/OVMF/OVMF_VARS_4M.fd"
    "arm64"   = "/usr/share/AAVMF/AAVMF_VARS.fd"
    "riscv64" = "/usr/share/qemu-efi-riscv64/RISCV_VIRT_VARS.fd"
  }
}

packer {
  required_plugins {
    qemu = {
      version = "~> 1"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

source "qemu" "packer" {
  qemu_binary = "qemu-system-${lookup(local.qemu_arch, var.arch, "")}"

  # VM Configuration
  cpus             = 8
  machine_type     = local.machine_type[var.arch]
  cpu_model        = local.can_kvm ? "host" : "max"
  accelerator      = local.can_kvm ? "kvm" : "tcg"
  memory           = 16384
  disk_image       = true
  disk_size        = "30G"
  iso_url          = var.iso_url
  iso_checksum     = var.iso_checksum
  format           = "qcow2"
  output_directory = "output-${var.vm_name}"
  vm_name          = "${var.vm_name}.qcow2"

  # Boot configuration
  efi_boot          = true
  efi_firmware_code = local.efi_firmware_code[var.arch]
  efi_firmware_vars = local.efi_firmware_vars[var.arch]
  boot_wait         = "10s"
  shutdown_command  = "poweroff"

  # cloud-init https://cloudinit.readthedocs.io/en/latest/reference/datasources/nocloud.html
  cd_files = ["user-data", "meta-data"]
  cd_label = "cidata"

  # Network and display
  net_device       = "virtio-net"
  disk_interface   = "virtio"
  headless         = true
  # Fix port only for debug, not for production parallel build, otherwise it will cause port conflict
  # vnc_bind_address = "0.0.0.0"
  # vnc_port_min     = 5900
  # vnc_port_max     = 5900
  # host_port_min    = 2222
  # host_port_max    = 2222

  # SSH Configuration
  ssh_username = "root"
  ssh_password = "packer"
  ssh_timeout  = "20m" # cross builds takes long time
}
