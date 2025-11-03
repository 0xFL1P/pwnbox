packer {
  required_plugins {
    vmware = {
      version = "~> 1"
      source  = "github.com/hashicorp/vmware"
    }
    vagrant = {
      version = "~> 1"
      source  = "github.com/hashicorp/vagrant"
    }
  }
}

variable "iso_path_local" {
  type    = string
  default = "./isos/archlinux-2025.10.01-x86_64.iso"
}

variable "iso_url" {
  type    = string
  default = "https://geo.mirror.pkgbuild.com/iso/latest/archlinux-x86_64.iso"
}

variable "iso_checksum_url" {
  type    = string
  default = "file:https://geo.mirror.pkgbuild.com/iso/latest/sha256sums.txt"
}

variable "disk_size" {
  type    = string
  default = "20480"
}

variable "cpus" {
  type    = string
  default = "1"
}

variable "cores" {
  type    = string
  default = "1"
}

variable "memory" {
  type    = string
  default = "1024"
}

variable "vm_name" {
  type    = string
  default = "pwnbox"
}

variable "ssh_username" {
  type    = string
  default = "vagrant"
}

variable "ssh_password" {
  type    = string
  default = "vagrant"
}

locals {
  iso_source = fileexists(var.iso_path_local) ? var.iso_path_local : var.iso_url
}


source "vmware-iso" "arch" {
  iso_url          = local.iso_source
  iso_checksum     = var.iso_checksum_url
  output_directory = "output"
  shutdown_command = "sudo systemctl poweroff"

  disk_size    = var.disk_size
  disk_type_id = "0"

  http_directory = "http"

  ssh_username = var.ssh_username
  ssh_password = var.ssh_password
  ssh_timeout  = "30m"
  ssh_port     = 22

  vm_name = var.vm_name
  memory  = var.memory
  cpus    = var.cpus
  cores   = var.cores

  guest_os_type = "other6xlinux-64"
  version       = "21"

  vmx_data = {
    "ethernet0.virtualdev" = "vmxnet3"
    "scsi0.virtualDev"     = "lsilogic"
    "firmware"             = "efi"
  }

  boot_wait = "5s"
  boot_command = [
    "<enter><wait10><wait10><wait10><wait10>",
    "/usr/bin/curl -O http://{{ .HTTPIP }}:{{ .HTTPPort }}/enable-ssh.sh<enter><wait5>",
    "/usr/bin/bash ./enable-ssh.sh<enter>"
  ]
}

build {
  sources = ["source.vmware-iso.arch"]

  provisioner "shell" {
    execute_command   = "{{ .Vars }} COUNTRY=SG sudo -E -S bash '{{ .Path }}'"
    expect_disconnect = true
    script            = "scripts/install-base.sh"
  }

  post-processor "vagrant" {
    output = "builds/${var.vm_name}_{{.Provider}}.box"
  }
}
