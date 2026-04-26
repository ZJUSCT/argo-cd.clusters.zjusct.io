build {
  name = "build"
  source "source.qemu.packer" {
    cd_files = ["user-data", "meta-data"]
  }

  # put files to /run instead of /tmp to avoid systemd-tmpfiles-clean.service
  provisioner "file" {
    source      = "modules-always/header"
    destination = "/run/"
  }

  provisioner "file" {
    source      = "squid.crt"
    destination = "/run/"
  }

  provisioner "shell" {
    scripts = var.modules
  }

  post-processor "manifest" {
    output = "output/${var.vm_name}/manifest.json"
  }
}

build {
  name = "debug"
  source "source.qemu.packer" {
    cd_files = ["debug/user-data", "debug/meta-data"]

    # Fix port only for debug, not for production parallel build, otherwise it will cause port conflict
    vnc_bind_address = "0.0.0.0"
    vnc_port_min     = 5901
    vnc_port_max     = 5901
    host_port_min    = 2222
    host_port_max    = 2222
  }

  provisioner "shell" {
    inline = ["sleep infinity"]
  }
}
