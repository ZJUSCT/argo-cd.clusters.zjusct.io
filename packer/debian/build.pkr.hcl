build {
  name = "cloud-init"
  source "source.qemu.ubuntu" {
    iso_url      = "http://rook-ceph-rgw-ceph-objectstore.rook-ceph.svc/packer-images/debian/debian-13-generic-amd64.qcow2"
    #iso_url = "debian-13-generic-amd64.qcow2"

    # cloud-init https://cloudinit.readthedocs.io/en/latest/reference/datasources/nocloud.html
    # note: nocloud datasource requires the meta-data file, or it will fail with "Invalid seed"
    cd_files = ["user-data", "meta-data"]
    cd_label = "cidata"

    output_directory = "output-cloud-init"
    vm_name          = "cloud-init.qcow2"
  }

  provisioner "shell" {
    inline = [
      "echo 'Waiting for cloud-init to complete...'",
      "cloud-init status --wait --long",
      "echo 'System is ready!'"
    ]
    # https://cloudinit.readthedocs.io/en/latest/explanation/failure_states.html#cloud-init-error-codes
    # allow cloud-init recoverable errors
    valid_exit_codes = [0, 2]
  }

  provisioner "shell" {
    environment_vars = [
      "DEBIAN_FRONTEND=noninteractive",
    ]
    inline = [
      "echo 'Cleaning up the system...'",
      "cloud-init clean --logs",
      "apt-get autoremove --purge -yq",
      "apt-get clean -yq",
    ]
  }

  post-processor "manifest" {
    output = "output-cloud-init/cloud-init-manifest.json"
  }
}

build {
  name = "customize"

  source "source.qemu.ubuntu" {
    iso_url = "http://rook-ceph-rgw-ceph-objectstore.rook-ceph.svc/packer-images/debian/cloud-init.qcow2"

    output_directory = "output-customize"
    vm_name          = "customize.qcow2"
  }

  provisioner "file" {
    source = "rootfs/"
    destination = "/tmp/rootfs"
  }

  provisioner "shell" {
    environment_vars = [
      "DEBIAN_FRONTEND=noninteractive",
      # "http_proxy=http://172.28.0.4:3128",
      # "https_proxy=http://172.28.0.4:3128"
    ]
    scripts = [
      "scripts/01-software.sh",
      "scripts/02-config.sh",
      "scripts/99-clean.sh"
    ]
  }

  post-processor "manifest" {
    output = "output-customize/customize-manifest.json"
  }
}
