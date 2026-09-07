# Live-tier harness for the proxmox-vm catalog. Boots one minimal VM on a
# reserved vmid (no ISO: this proves catalog wiring, not guest OS health).

terraform {
  required_version = ">= 1.12.5"

  required_providers {
    proxmox = {
      source = "telmate/proxmox"
      # Version tracked here: see infrastructure/catalogs/public/proxmox-vm/main.tf
      version = "3.0.2-rc10"
    }
    random = {
      source  = "opentofu/random"
      version = "3.9.0"
    }
  }
}

variable "pm_api_url" {
  description = "Proxmox API base URL, e.g. https://192.0.2.1:8006/"
  type        = string
}

variable "pm_api_token_id" {
  description = "API token id of the restricted ci-runner@pve user"
  type        = string
}

variable "pm_api_token_secret" {
  description = "API token secret of the restricted ci-runner@pve user"
  type        = string
  sensitive   = true
}

variable "pm_target_node" {
  description = "Proxmox node that hosts the test guests"
  type        = string
}

variable "pm_bridge" {
  description = "Bridge the test guests attach to"
  type        = string
  default     = "vmbr0"
}

provider "proxmox" {
  pm_api_url          = var.pm_api_url
  pm_api_token_id     = var.pm_api_token_id
  pm_api_token_secret = var.pm_api_token_secret
  pm_tls_insecure     = true
}

module "under_test" {
  source = "../../../catalogs/public/proxmox-vm"

  proxmox = {
    api_url          = var.pm_api_url
    api_token_id     = var.pm_api_token_id
    api_token_secret = var.pm_api_token_secret
    node_name        = var.pm_target_node
  }

  vms = {
    "tftest-live-vm" = {
      disk_capacity            = "4G"
      additional_disk_capacity = null
      name                     = null
      vmid                     = 5901
      # telmate 3.0.2-rc07+ rejects the "" that the catalog maps a null
      # macaddr to, so the fixture pins a valid address.
      macaddr                 = "bc:24:11:2a:3b:4c"
      vmodel                  = "virtio"
      vnetwork                = var.pm_bridge
      additional_vnetwork     = null
      vnetwork_tag            = null
      additional_vnetwork_tag = null
      vcores                  = 1
      vram                    = 1024
      tags                    = "ci;tftest"
    }
  }

  vm_details = {
    agent_number       = 0
    socket_number      = 1
    cpu_type           = "kvm64"
    scsihw             = "virtio-scsi-pci"
    qemu_os            = "other"
    target_node        = var.pm_target_node
    start_at_node_boot = false
    iso_name           = null
    storage            = "local-lvm"
    ipconfig           = "ip=dhcp"
    nameserver         = "192.0.2.53"
  }
}
