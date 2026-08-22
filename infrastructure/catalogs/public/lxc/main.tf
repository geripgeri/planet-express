terraform {
  required_version = ">= 1.12.5"
  required_providers {
    proxmox = {
      source  = "telmate/proxmox"
      version = "3.0.2-rc09"
    }
  }
}

resource "proxmox_lxc" "this" {
  for_each = var.containers

  target_node  = var.container_details.target_node
  hostname     = each.key
  vmid         = each.value.vmid
  ostemplate   = var.container_details.ostemplate
  unprivileged = var.container_details.unprivileged
  start        = var.container_details.start
  onboot       = var.container_details.onboot

  cores  = each.value.cores
  memory = each.value.memory

  nameserver = var.container_details.nameserver
  tags       = each.value.tags

  ssh_public_keys = var.container_details.ssh_public_keys

  rootfs {
    storage = var.container_details.storage
    size    = each.value.disk_size
  }

  network {
    name   = "eth0"
    bridge = each.value.network.bridge
    ip     = each.value.network.ip
    gw     = each.value.network.gw
    tag    = each.value.network.tag
  }

  dynamic "network" {
    for_each = each.value.additional_network != null ? [1] : []
    content {
      name   = "eth1"
      bridge = each.value.additional_network.bridge
      ip     = each.value.additional_network.ip
      gw     = each.value.additional_network.gw
      tag    = each.value.additional_network.tag
    }
  }
}
