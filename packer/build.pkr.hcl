build {
  name = "packer"
  source "source.qemu.packer" {}

  provisioner "file" {
    source      = "modules-always/00-shared.sh"
    destination = "/tmp/"
  }

  provisioner "file" {
    source      = "squid.crt"
    destination = "/tmp/"
  }

  provisioner "shell" {
    scripts = var.modules
  }

  post-processor "manifest" {
    output = "output/${var.vm_name}/manifest.json"
  }
}
