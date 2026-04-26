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
  default = ["modules-always/header"]
}

variable "qemu_binary" {
  type    = string
  default = "qemu-system-x86_64"
}

variable "machine_type" {
  type    = string
  default = "pc"
}

variable "cpu_model" {
  type    = string
  default = "max"
}

variable "accelerator" {
  type    = string
  default = "tcg"
}

variable "efi_firmware_code" {
  type    = string
  default = "/usr/share/OVMF/OVMF_CODE_4M.fd"
}

variable "efi_firmware_vars" {
  type    = string
  default = "/usr/share/OVMF/OVMF_VARS_4M.fd"
}
