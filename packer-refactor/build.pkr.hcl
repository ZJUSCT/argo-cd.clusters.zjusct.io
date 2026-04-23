build {
  name = "packer"
  source "source.qemu.ubuntu" {}

  provisioner "file" {
    source      = "modules/common.sh"
    destination = "/tmp/"
  }

  provisioner "file" {
    source      = "ansible"
    destination = "/tmp"
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
