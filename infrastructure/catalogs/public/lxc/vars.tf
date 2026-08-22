# Consumed by the provider block generated in units/public/proxmox/base.hcl.
#tflint-ignore: terraform_unused_declarations
variable "proxmox" {
  description = "Provider Configuration"
  type = object({
    api_url          = string
    api_token_id     = string
    api_token_secret = string
    node_name        = string
  })
}

variable "containers" {
  description = "LXC container details, keyed by hostname; `tags` is semicolon-delimited"
  type = map(object({
    vmid      = number
    cores     = number
    memory    = number
    disk_size = string
    network = object({
      bridge = string
      ip     = optional(string) # CIDR or "dhcp"
      gw     = optional(string)
      tag    = optional(number) # VLAN tag, e.g. 20 for the VPN network
    })
    additional_network = optional(object({
      bridge = string
      ip     = optional(string)
      gw     = optional(string)
      tag    = optional(number)
    }))
    tags = string
  }))
}

variable "container_details" {
  description = "LXC generic settings"
  type = object({
    target_node     = string
    ostemplate      = string
    storage         = string
    nameserver      = string
    unprivileged    = bool
    ssh_public_keys = optional(string)
    start           = bool
    onboot          = bool
  })
}
