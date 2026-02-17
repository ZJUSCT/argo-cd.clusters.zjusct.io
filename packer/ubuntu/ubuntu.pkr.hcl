packer {
  required_plugins {
    qemu = {
      version = "~> 1"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

source "null" "dependencies" {
  communicator = "none"
}

# https://developer.hashicorp.com/packer/integrations/hashicorp/qemu/latest/components/builder/qemu
source "qemu" "ubuntu" {
  # iso_url      = "https://mirror.nju.edu.cn/ubuntu-cloud-images/questing/current/questing-server-cloudimg-amd64.img"
  # iso_checksum = "file:https://mirror.nju.edu.cn/ubuntu-cloud-images/questing/current/SHA256SUMS"
  iso_url = "questing-server-cloudimg-amd64.img"
  iso_checksum = "file:/workspace/ubuntu/SHA256SUMS"
  disk_image   = true
  efi_boot = true

  # VM Configuration
  cpus            = 4
  memory          = 16384
  disk_size       = "20G"
  format          = "qcow2"
  accelerator     = "kvm"
  headless        = true

  # Network and display
  net_device       = "virtio-net"
  disk_interface   = "virtio"
  vnc_bind_address = "127.0.0.1"

  # Boot configuration
  boot_wait = "10s"

  # SSH Configuration
  ssh_username = "ubuntu"
  ssh_password = "ubuntu"
  ssh_timeout  = "20m"

  # Output
  output_directory = "output"
  vm_name          = "ubuntu.qcow2"

  # cloud-init https://cloudinit.readthedocs.io/en/latest/reference/datasources/nocloud.html
  floppy_files = ["user-data", "meta-data"]
  floppy_label = "cidata"

  # Shutdown
  shutdown_command = "sudo -S shutdown -P now"
}

# build {
#   name    = "cloudimg.deps"
#   sources = ["source.null.dependencies"]
#
#   provisioner "shell-local" {
#     inline = [
#       "cloud-localds seeds-cloudimg.iso user-data meta-data",
#       "cp /usr/share/OVMF/OVMF_VARS.fd output/efivars.fd"
#     ]
#     inline_shebang = "/bin/bash -e"
#   }
# }

build {
  name    = "cloudimg.image"
  sources = ["source.qemu.ubuntu"]

  # Wait for system to be ready
  provisioner "shell" {
    inline = [
      "echo 'Waiting for cloud-init to complete...'",
      "cloud-init status --wait",
      "echo 'System is ready!'"
    ]
  }

  # Cleanup
  provisioner "shell" {
    inline = [
      "echo 'Cleaning up...'",
      "echo 'ubuntu' | sudo -S apt-get autoremove -y",
      "echo 'ubuntu' | sudo -S apt-get clean",
      "echo 'ubuntu' | sudo -S cloud-init clean --logs",
      "echo 'ubuntu' | sudo -S rm -f /etc/ssh/ssh_host_*",
      "echo 'ubuntu' | sudo -S truncate -s 0 /etc/machine-id",
      "echo 'ubuntu' | sudo -S sync"
    ]
  }
}
