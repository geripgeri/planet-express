output "ip_addresses" {
  description = "Map associating each container key with its configured eth0 IPv4 address (the static address from `network.ip`; LXC resources expose no provider-discovered address)"
  value       = { for k, v in proxmox_lxc.this : k => v.network[0].ip }
}

output "vmids" {
  description = "Map linking each container key to its unique Proxmox VMID"
  value       = { for k, v in proxmox_lxc.this : k => v.vmid }
}
