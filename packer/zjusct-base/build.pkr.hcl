build {
  name = "zjusct-base"
  source "source.qemu.ubuntu" {
    #iso_url = "https://mirrors.cernet.edu.cn/debian-cdimage/cloud/trixie/latest/debian-13-generic-amd64.qcow2"
    iso_url = "debian-13-generic-amd64.qcow2"
    #iso_checksum = "file:https://mirrors.cernet.edu.cn/debian-cdimage/cloud/trixie/latest/SHA512SUMS"
    iso_checksum = "file:SHA512SUMS"
    #iso_checksum = "none"

    # cloud-init https://cloudinit.readthedocs.io/en/latest/reference/datasources/nocloud.html
    # note: nocloud datasource requires the meta-data file, or it will fail with "Invalid seed"
    cd_files = ["user-data", "meta-data"]
    cd_label = "cidata"

    output_directory = "output"
    vm_name          = "zjusct-base.qcow2"
  }

  provisioner "shell" {
    scripts = [
      "scripts/00-wait-cloud-init.sh"
    ]
    # https://cloudinit.readthedocs.io/en/latest/explanation/failure_states.html#cloud-init-error-codes
    # allow cloud-init recoverable errors
    valid_exit_codes = [0, 2]
  }

  # https://developer.hashicorp.com/packer/docs/provisioners/file#directory-uploads
  # Notice rsync syntax
  provisioner "file" {
    source      = "rootfs"
    destination = "/tmp"
  }

  provisioner "shell" {
    environment_vars = [
      "DEBIAN_FRONTEND=noninteractive",
      "http_proxy=http://172.28.0.4:3128",
      "https_proxy=http://172.28.0.4:3128"
    ]
    scripts = [
      "scripts/01-software.sh",
      "scripts/02-config.sh",
      "scripts/99-clean.sh"
    ]
  }

  post-processor "manifest" {
    output = "output/zjusct-base-manifest.json"
  }
}
