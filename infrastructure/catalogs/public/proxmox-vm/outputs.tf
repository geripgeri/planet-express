output "ip_addresses" {
  description = "A map associating each virtual machine key with its assigned default IPv4 address. When static_ip_addresses is set, returns those values for one-shot stack (qemu-guest-agent not required)."
  value       = length(var.static_ip_addresses) > 0 ? var.static_ip_addresses : { for k, v in proxmox_vm_qemu.this : k => v.default_ipv4_address }
}

output "vmids" {
  description = "A map linking each virtual machine key to its unique Proxmox VM ID."
  value       = { for k, v in proxmox_vm_qemu.this : k => v.vmid }
}
