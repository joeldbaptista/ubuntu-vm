variable "vm_name" {
  description = "Name of the VM and prefix of every libvirt object this project creates"
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9._-]*$", var.vm_name))
    error_message = "vm_name must start with a letter or digit and contain only letters, digits, dots, underscores and hyphens."
  }
}

variable "vcpu" {
  description = "Number of virtual CPUs"
  type        = number
  default     = 2
}

variable "memory_mb" {
  description = "Guest memory in MiB"
  type        = number
  default     = 4096
}

variable "disk_gb" {
  description = "Guest disk size in GiB"
  type        = number
  default     = 16
}

variable "base_image_url" {
  description = "URL of the Ubuntu Server cloud image (qcow2) used as the base disk"
  type        = string
  default     = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
}

variable "libvirt_uri" {
  description = "libvirt connection URI"
  type        = string
  default     = "qemu:///system"
}

variable "storage_pool" {
  description = "Existing libvirt storage pool holding the VM disks. This project references the pool and never manages it"
  type        = string
  default     = "default"
}

variable "network_name" {
  description = "Existing libvirt network the VM attaches to"
  type        = string
  default     = "default"
}

variable "ssh_user" {
  description = "Login account created in the guest by cloud-init"
  type        = string
  default     = "ubuntu"
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key injected into the guest"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}
