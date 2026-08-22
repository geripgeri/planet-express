locals {
  worker_count = 3

  # Shared Proxmox guest config: provider auth, vlan-10 resolvers, template pin.
  proxmox_base = read_terragrunt_config("${get_repo_root()}/infrastructure/units/public/proxmox/base.hcl")

  worker_defaults = {
    disk_capacity            = "15G"
    additional_disk_capacity = "100G"
    vcores                   = 4
    vram                     = 4096
    tags                     = "talos,worker"
    vmodel                   = "virtio"
    vnetwork                 = "vmbr0"
    vnetwork_tag             = 20
    additional_vnetwork      = "vmbr0"
  }

  workers = {
    for i in range(1, local.worker_count + 1) :
    format("talos-worker-%02d", i) => merge(local.worker_defaults, {
      vmid    = 500 + i
      macaddr = format("AA:BB:CC:DD:05:%02X", i)
    })
  }
}

include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "proxmox_base" {
  path = "${get_repo_root()}/infrastructure/units/public/proxmox/base.hcl"
}

terraform {
  source = "${get_repo_root()}//infrastructure/catalogs/public/proxmox-vm"
}

inputs = {
  proxmox = local.proxmox_base.locals.secret_vars.proxmox

  vm_details = {
    agent_number       = 1
    socket_number      = 1
    cpu_type           = "x86-64-v2-AES"
    scsihw             = "virtio-scsi-pci"
    qemu_os            = "l26"
    target_node        = local.proxmox_base.locals.secret_vars.proxmox.node_name
    start_at_node_boot = true
    iso_name           = "local:iso/talos-linuxnocloud-amd64.iso"
    storage            = "local-lvm"
    ipconfig           = "ip=dhcp"
    nameserver         = local.proxmox_base.locals.guest_nameservers
  }

  vms = merge(
    {
      talos-controller-01 = {
        disk_capacity       = "10G"
        vmid                = 500
        macaddr             = "AA:BB:CC:DD:05:00"
        vcores              = 2
        vram                = 2048
        tags                = "talos,controller"
        vmodel              = "virtio"
        vnetwork            = "vmbr0"
        vnetwork_tag        = 20
        additional_vnetwork = "vmbr0"
      }
    },
    local.workers
  )
}
