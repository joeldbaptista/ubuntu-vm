output "vm_name" {
  description = "Name of the VM, as libvirt knows it"
  value       = libvirt_domain.vm.name
}

output "disk_path" {
  description = "Host path of the VM disk, which is what the snapshot script copies"
  value       = libvirt_volume.disk.path
}

output "ssh_user" {
  description = "Account to log in with once the VM has an address"
  value       = var.ssh_user
}
