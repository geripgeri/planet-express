variable "talos_cluster_details" {
  description = "The Talos cluster details"
  type = object({
    name               = string
    version            = string
    kubernetes_version = string
    longhorn_disk_size = string
  })

  validation {
    condition     = var.talos_cluster_details.name != ""
    error_message = "Cluster name must not be empty."
  }

  validation {
    condition     = can(regex("^v?[0-9]+\\.[0-9]+\\.[0-9]+(-[a-zA-Z0-9.-]+)?$", var.talos_cluster_details.version))
    error_message = "Version must be a valid semantic version (e.g., v1.2.3 or 1.2.3-alpha)."
  }

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.talos_cluster_details.kubernetes_version))
    error_message = "Kubernetes version must be a valid semantic version (e.g., 1.35.0)."
  }

  validation {
    condition     = can(regex("^[0-9]+(GB|TB)$", var.talos_cluster_details.longhorn_disk_size))
    error_message = "Longhorn disk size must be a string like '100GB' or '1TB'."
  }
}

variable "controller_ips" {
  description = "List of IPv4 addresses for each Talos controller nodes"
  type        = list(string)

  validation {
    condition     = length(var.controller_ips) > 0 && alltrue([for ip in var.controller_ips : can(regex("^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$", ip))])
    error_message = "Each controller IP must be a valid IPv4 address, and the list must not be empty."
  }
}

variable "workers" {
  description = "Map of worker nodes with their IP and VMID"
  type = map(object({
    ip   = string
    vmid = number
  }))

  validation {
    condition     = alltrue([for _, worker in var.workers : can(regex("^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$", worker.ip))])
    error_message = "Each worker node IP must be a valid IPv4 address."
  }

  validation {
    condition     = alltrue([for _, worker in var.workers : worker.vmid >= 100])
    error_message = "Worker VMIDs must be 100 or greater, consistent with Proxmox conventions."
  }
}

variable "controller_vmid" {
  description = "The VM ID of the Talos controller node running in Proxmox."
  type        = number

  validation {
    condition     = var.controller_vmid >= 100
    error_message = "Proxmox VM IDs typically start at 100. Please enter a valid ID."
  }
}

variable "network_config" {
  description = "Map of VLAN configurations including subnets, gateways, and nameservers."
  type = map(object({
    subnet      = string
    gateway     = string
    nameservers = list(string)
    mtu         = optional(number, 1500)
  }))

  default = {}

  validation {
    condition = alltrue([
      for vlan, config in var.network_config :
      can(regex("^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)/(3[0-2]|[12]?[0-9])$", config.subnet)) &&
      can(regex("^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$", config.gateway)) &&
      alltrue([for ns in config.nameservers : can(regex("^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$", ns))]) &&
      (config.mtu == null || (config.mtu >= 576 && config.mtu <= 65535))
    ])
    error_message = "Each VLAN config must have a valid CIDR subnet, valid IPv4 gateway, valid IPv4 nameservers, and MTU between 576 and 65535 (if specified)."
  }
}
