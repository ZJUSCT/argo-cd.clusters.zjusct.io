packer {
  required_plugins {
    qemu = {
      version = "~> 1"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

source "qemu" "ubuntu" {
  # Use Ubuntu 22.04 LTS (Jammy) cloud image
  iso_url      = "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
  iso_checksum = "file:https://cloud-images.ubuntu.com/jammy/current/SHA256SUMS"
  disk_image   = true

  # VM Configuration
  cpus            = 2
  memory          = 2048
  disk_size       = "10G"
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

  # HTTP server for cloud-init files
  http_directory = "."

  # Output
  output_directory = "output"
  vm_name          = "ubuntu-simple.qcow2"

  # QEMU arguments for cloud-init
  qemuargs = [
    ["-smbios", "type=1,serial=ds=nocloud-net;s=http://{{.HTTPIP}}:{{.HTTPPort}}/"]
  ]

  # Shutdown
  shutdown_command = "echo 'ubuntu' | sudo -S shutdown -P now"
}

build {
  sources = ["source.qemu.ubuntu"]

  # Wait for system to be ready
  provisioner "shell" {
    inline = [
      "echo 'Waiting for cloud-init to complete...'",
      "cloud-init status --wait",
      "echo 'System is ready!'"
    ]
  }

  # Update system
  provisioner "shell" {
    inline = [
      "echo 'ubuntu' | sudo -S apt-get update",
      "echo 'ubuntu' | sudo -S apt-get upgrade -y"
    ]
  }

  # Install any additional packages (example)
  provisioner "shell" {
    inline = [
      "echo 'ubuntu' | sudo -S apt-get install -y curl wget vim"
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
