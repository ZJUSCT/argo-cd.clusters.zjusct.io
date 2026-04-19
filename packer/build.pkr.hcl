build {
  name = "zjusct-base"
  source "source.qemu.ubuntu" {
    disk_size = "30G"

    # # local
    # iso_url      = "debian-13-generic-amd64.qcow2"
    # iso_checksum = "file:SHA512SUMS"
    # # remote
    # iso_url = "https://mirrors.cernet.edu.cn/debian-cdimage/cloud/trixie/latest/debian-13-generic-amd64.qcow2"
    # iso_checksum = "file:https://mirrors.cernet.edu.cn/debian-cdimage/cloud/trixie/latest/SHA512SUMS"

    # # pipeline
    # iso_url = "http://rook-ceph-rgw-ceph-objectstore.rook-ceph.svc/packer-images/upstream/debian-13-generic-amd64.qcow2"
    # iso_checksum = "file:http://rook-ceph-rgw-ceph-objectstore.rook-ceph.svc/packer-images/upstream/SHA512SUMS"
    # local pipeline
    iso_url = "https://radosgw.clusters.zjusct.io/packer-images/upstream/debian-13-generic-amd64.qcow2"
    iso_checksum = "file:http://radosgw.clusters.zjusct.io/packer-images/upstream/SHA512SUMS"

    # cloud-init https://cloudinit.readthedocs.io/en/latest/reference/datasources/nocloud.html
    cd_files = ["base/user-data", "base/meta-data"]
    cd_label = "cidata"

    output_directory = "output-base"
    vm_name          = "zjusct-base.qcow2"
  }

  provisioner "shell" {
    scripts = [
      "00-wait-cloud-init.sh"
    ]
    valid_exit_codes = [0, 2]
  }

  provisioner "file" {
    source      = "base/rootfs"
    destination = "/tmp"
  }

  provisioner "shell" {
    environment_vars = [
      "DEBIAN_FRONTEND=noninteractive",
      "http_proxy=http://172.28.0.4:3128",
      "https_proxy=http://172.28.0.4:3128"
    ]
    scripts = [
      "base/scripts/01-software.sh",
      "base/scripts/02-config.sh",
      "base/scripts/10-claude.sh",
      "base/scripts/10-doca.sh",
      "99-clean.sh"
    ]
  }

  post-processor "manifest" {
    output = "output-base/zjusct-base-manifest.json"
  }
}

build {
  name = "zjusct-full"
  source "source.qemu.ubuntu" {
    disk_size    = "30G"
    iso_url      = "output-base/zjusct-base.qcow2"
    iso_checksum = "none"

    # cloud-init https://cloudinit.readthedocs.io/en/latest/reference/datasources/nocloud.html
    cd_files = ["full/user-data", "full/meta-data"]
    cd_label = "cidata"

    output_directory = "output-full"
    vm_name          = "zjusct-full.qcow2"
  }

  provisioner "shell" {
    scripts = [
      "00-wait-cloud-init.sh"
    ]
    valid_exit_codes = [0, 2]
  }

  provisioner "file" {
    source      = "full/rootfs"
    destination = "/tmp"
  }

  provisioner "shell" {
    environment_vars = [
      "DEBIAN_FRONTEND=noninteractive",
      "http_proxy=http://172.28.0.4:3128",
      "https_proxy=http://172.28.0.4:3128"
    ]
    scripts = [
      "full/scripts/01-software.sh",
      "full/scripts/02-config.sh",
      "99-clean.sh"
    ]
  }

  post-processor "manifest" {
    output = "output-full/zjusct-full-manifest.json"
  }
}
