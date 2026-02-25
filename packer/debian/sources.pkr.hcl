# https://developer.hashicorp.com/packer/integrations/hashicorp/qemu/latest/components/builder/qemu

packer {
  required_plugins {
    qemu = {
      version = "~> 1"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

source "qemu" "ubuntu" {

  disk_image = true
  efi_boot   = true

  # VM Configuration
  cpus        = 8
  memory      = 16384
  disk_size   = "30G"
  format      = "qcow2"
  accelerator = "kvm"
  headless    = true

  # Network and display
  net_device       = "virtio-net"
  disk_interface   = "virtio"
  vnc_bind_address = "127.0.0.1"

  # Boot configuration
  boot_wait = "10s"

  # SSH Configuration
  ssh_username = "root"
  ssh_password = "ubuntu"
  ssh_timeout  = "20m"

  iso_checksum = "none"

  # Shutdown
  shutdown_command = "shutdown -P now"

  qemuargs = [
    ["-cpu", "host"]
  ]
}
