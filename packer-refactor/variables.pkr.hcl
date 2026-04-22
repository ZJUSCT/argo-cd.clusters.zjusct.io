variable "arch" {
  type    = string
  default = "amd64"
}

variable "host_arch" {
  type    = string
  default = "amd64"
}

variable "iso_url" {
  type    = string
  default = "none.qcow2"
}

variable "iso_checksum" {
  type    = string
  default = "none"
}

variable "vm_name" {
  type    = string
  default = "output"
}

variable "modules" {
  type    = list(string)
  default = []
}
