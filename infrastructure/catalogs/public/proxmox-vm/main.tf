terraform {
  required_version = ">= 1.12.5"
  required_providers {
    proxmox = {
      source = "telmate/proxmox"
      # rc10 fixed the double-start bug that made rc08/rc09 fail with
      # "VM already running" on fresh create (Telmate/terraform-provider-proxmox#1542).
      version = "3.0.2-rc10"
    }
    random = {
      source  = "opentofu/random"
      version = "3.9.0"
    }
  }
}

resource "proxmox_vm_qemu" "this" {
  for_each = var.vms

  name        = each.key
  target_node = var.vm_details.target_node
  vmid        = each.value.vmid

  # Basic VM settings here. agent refers to guest agent
  agent         = var.vm_details.agent_number
  agent_timeout = 15

  cpu {
    type    = var.vm_details.cpu_type
    cores   = each.value.vcores
    sockets = var.vm_details.socket_number
  }

  memory             = each.value.vram
  scsihw             = var.vm_details.scsihw
  qemu_os            = var.vm_details.qemu_os
  start_at_node_boot = var.vm_details.start_at_node_boot

  disks {
    dynamic "ide" {
      for_each = var.vm_details.iso_name != null ? [1] : []
      content {
        ide0 {
          cdrom {
            iso = var.vm_details.iso_name
          }
        }
      }
    }

    dynamic "scsi" {
      for_each = each.value.disk_capacity != null ? [1] : []
      content {
        dynamic "scsi0" {
          for_each = each.value.disk_capacity != null ? [1] : []
          content {
            disk {
              size    = each.value.disk_capacity
              storage = var.vm_details.storage
            }
          }
        }

        dynamic "scsi1" {
          for_each = each.value.additional_disk_capacity != null ? [1] : []
          content {
            disk {
              size    = each.value.additional_disk_capacity
              storage = var.vm_details.storage
            }
          }
        }
      }
    }
  }

  network {
    id      = 0
    model   = each.value.vmodel
    bridge  = each.value.vnetwork
    macaddr = each.value.macaddr != null ? each.value.macaddr : ""
  }

  # Secondary network usually VLAN tagged
  dynamic "network" {
    for_each = each.value.additional_vnetwork != null ? [1] : []
    content {
      id     = 1
      model  = each.value.vmodel
      bridge = each.value.additional_vnetwork
      tag    = each.value.additional_vnetwork_tag
    }
  }

  skip_ipv6 = true

  startup_shutdown {
    order            = -1
    shutdown_timeout = -1
    startup_delay    = -1
  }


  lifecycle {
    ignore_changes = [
      disks, target_node
    ]
  }

  ipconfig0  = var.vm_details.ipconfig
  nameserver = var.vm_details.nameserver

  tags = each.value.tags
}
