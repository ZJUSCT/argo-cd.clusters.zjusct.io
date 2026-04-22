build {
  name = "packer"
  source "source.qemu.ubuntu" {
    disk_size = "30G"

    iso_url      = var.iso_url
    iso_checksum = var.iso_checksum

    # cloud-init https://cloudinit.readthedocs.io/en/latest/reference/datasources/nocloud.html
    cd_files = ["user-data", "meta-data"]
    cd_label = "cidata"

    output_directory = "output-${var.vm_name}"
    vm_name          = "${var.vm_name}.qcow2"
  }

  provisioner "file" {
    source      = "modules/common.sh"
    destination = "/tmp/"
  }

  provisioner "shell" {
    scripts = [
      "modules/00-bootstrap.sh"
    ]
    valid_exit_codes = [0, 2]
  }

  provisioner "shell" {
    scripts = concat(var.modules, [
      "modules/99-clean.sh"
      ]
    )
  }

  post-processor "manifest" {
    output = "output-${var.vm_name}/manifest.json"
  }
}
