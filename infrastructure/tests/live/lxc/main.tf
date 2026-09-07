# Live-tier harness for the lxc catalog. Deploys ONE tiny throwaway guest
# on the reserved test vmid range, asserts it came up, tears down again.
# Runs only on the self-hosted runner (needs the real Proxmox API).

terraform {
  required_version = ">= 1.12.5"

  required_providers {
    proxmox = {
      source = "telmate/proxmox"
      # Version tracked here: see infrastructure/catalogs/public/lxc/main.tf
      version = "3.0.2-rc10"
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

variable "lxc_ostemplate" {
  description = "Volume path of the Debian LXC template. Mirrors the Renovate-managed pin in ansible/roles/proxmox_base/defaults/main.yaml; update together."
  type        = string
  default     = "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
}

provider "proxmox" {
  pm_api_url          = var.pm_api_url
  pm_api_token_id     = var.pm_api_token_id
  pm_api_token_secret = var.pm_api_token_secret
  pm_tls_insecure     = true # self-signed cert until replaced, see base.hcl
}

module "under_test" {
  source = "../../../catalogs/public/lxc"

  proxmox = {
    api_url          = var.pm_api_url
    api_token_id     = var.pm_api_token_id
    api_token_secret = var.pm_api_token_secret
    node_name        = var.pm_target_node
  }

  containers = {
    "tftest-live-lxc" = {
      vmid      = 5900
      cores     = 1
      memory    = 512
      disk_size = "2G"
      network = {
        bridge = var.pm_bridge
        ip     = "dhcp"
        tag    = 20
      }
      tags = "ci;tftest"
    }
  }

  container_details = {
    target_node     = var.pm_target_node
    ostemplate      = var.lxc_ostemplate
    storage         = "local-lvm"
    nameserver      = "192.0.2.53"
    unprivileged    = true
    ssh_public_keys = ""
    start           = true
    onboot          = false
  }
}
