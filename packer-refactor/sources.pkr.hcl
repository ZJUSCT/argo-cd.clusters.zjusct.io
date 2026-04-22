# https://developer.hashicorp.com/packer/integrations/hashicorp/qemu/latest/components/builder/qemu

locals {
  qemu_arch = {
    "x86_64"   = "x86_64"
    "arm64"   = "aarch64"
    "riscv64" = "riscv64"
  }
  machine_type = {
    "x86_64"   = "pc"
    "arm64"   = "virt"
    "riscv64" = "virt"
  }
  can_kvm = var.host_arch == var.arch
  efi_firmware_code = {
    "x86_64"   = "/usr/share/OVMF/OVMF_CODE_4M.fd"
    "arm64"   = "/usr/share/AAVMF/AAVMF_CODE.fd"
    "riscv64" = "/usr/share/qemu-efi-riscv64/RISCV_VIRT_CODE.fd"
  }
  efi_firmware_vars = {
    "x86_64"   = "/usr/share/OVMF/OVMF_CODE_4M.fd"
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

source "qemu" "ubuntu" {

  disk_image        = true
  efi_boot          = true
  efi_firmware_code = local.efi_firmware_code[var.arch]
  efi_firmware_vars = local.efi_firmware_vars[var.arch]

  # VM Configuration
  cpus        = 32
  memory      = 16384
  format      = "qcow2"
  accelerator = local.can_kvm ? "kvm" : "tcg"
  headless    = true

  machine_type = local.machine_type[var.arch]
  cpu_model    = local.can_kvm ? "host" : "max"

  qemu_binary = "qemu-system-${lookup(local.qemu_arch, var.arch, "")}"

  # Network and display
  net_device       = "virtio-net"
  disk_interface   = "virtio"
  vnc_bind_address = "127.0.0.1"

  # Boot configuration
  boot_wait = "10s"

  # SSH Configuration
  ssh_username = "root"
  ssh_password = "ubuntu"
  ssh_timeout  = "5m"

  # Shutdown
  shutdown_command = "poweroff"
}
