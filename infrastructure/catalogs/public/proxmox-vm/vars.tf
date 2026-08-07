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
