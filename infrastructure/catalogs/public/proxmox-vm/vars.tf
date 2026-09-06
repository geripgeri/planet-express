variable "proxmox" {
  description = "Provider Configuration"
  type = object({
    api_url          = string
    api_token_id     = string
    api_token_secret = string
    node_name        = string
  })
}

variable "vms" {
  description = "Virtual Machine Details"
  type = map(object({
    disk_capacity            = string
    additional_disk_capacity = optional(string)
    name                     = optional(string)
    vmid                     = number
    macaddr                  = optional(string)
    vmodel                   = string
    vnetwork                 = string
    additional_vnetwork      = string
    vnetwork_tag             = optional(number)
    additional_vnetwork_tag  = optional(number)
    vcores                   = number
    vram                     = number
    tags                     = string
  }))
}

variable "vm_details" {
  description = "VM generic settings"
  type = object({
    agent_number       = number
    socket_number      = number
    cpu_type           = string
    scsihw             = string
    qemu_os            = string
    target_node        = string
    start_at_node_boot = bool
    iso_name           = string
    storage            = string
    ipconfig           = string
    nameserver         = string
  })
}

variable "static_ip_addresses" {
  description = "Optional static IPv4 addresses per VM key. When set, ip_addresses output returns these instead of default_ipv4_address (qemu-guest-agent). Enables one-shot stack without waiting for guest agent."
  type        = map(string)
  default     = {}

  validation {
    condition     = alltrue([for ip in values(var.static_ip_addresses) : can(regex("^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$", ip))])
    error_message = "Each static IP must be a valid IPv4 address."
  }
}
