locals {
  # Shared Proxmox guest config: provider auth, vlan-10 resolvers, template pin.
  proxmox_base = read_terragrunt_config("${get_repo_root()}/infrastructure/units/public/proxmox/base.hcl")

  # Shared Talos cluster identity + topology: cluster name, kubeconfig
  # context, controller and worker VMIDs/IPs (single source of truth).
  talos_base = read_terragrunt_config("${get_repo_root()}/infrastructure/units/public/talos/base.hcl")

  # Talos ISO version single source: proxmox_base defaults, like lxc_ostemplate in base.hcl.
  talos_iso_version = yamldecode(file("${get_repo_root()}/ansible/roles/proxmox_base/defaults/main.yaml")).proxmox_base_talos_iso_version

  worker_defaults = {
    disk_capacity            = "15G"
    additional_disk_capacity = "100G"
    vcores                   = 4
    vram                     = 4096
    tags                     = "talos,worker"
    vmodel                   = "virtio"
    vnetwork                 = "vmbr0"
    vnetwork_tag             = null
    additional_vnetwork      = "vmbr0"
    additional_vnetwork_tag  = 20
  }

  # Merge shared worker VMIDs/IPs (talos_base.workers) with this unit's
  # proxmox-specific defaults and a deterministic MAC per slot.
  workers = {
    for name, ws in local.talos_base.locals.workers :
    name => merge(local.worker_defaults, {
      vmid    = ws.vmid
      macaddr = format("AA:BB:CC:DD:05:%02X", tonumber(substr(name, -2, 2)))
    })
  }

  # Static IPs for one-shot stack: native bridge1 is DHCP but Talos IPs are
  # reserved via DHCP (controller .30, workers .31-.33). Shared topology in
  # talos/base.hcl owns the mapping; use it instead of qemu-guest-agent
  # default_ipv4_address which is empty until Talos extension installs.
  static_ips = merge(
    { "talos-controller-01" = local.talos_base.locals.controller_ip },
    { for name, ws in local.talos_base.locals.workers : name => ws.ip }
  )
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
  proxmox             = local.proxmox_base.locals.secret_vars.proxmox
  static_ip_addresses = local.static_ips

  vm_details = {
    agent_number       = 1
    socket_number      = 1
    cpu_type           = "x86-64-v2-AES"
    scsihw             = "virtio-scsi-pci"
    qemu_os            = "l26"
    target_node        = local.proxmox_base.locals.secret_vars.proxmox.node_name
    start_at_node_boot = true
    iso_name           = "local:iso/talos-${local.talos_iso_version}-nocloud-amd64.iso"
    storage            = "local-lvm"
    ipconfig           = "ip=dhcp"
    nameserver         = local.proxmox_base.locals.guest_nameservers
  }

  vms = merge(
    {
      talos-controller-01 = {
        disk_capacity           = "10G"
        vmid                    = local.talos_base.locals.controller_vmid
        macaddr                 = "AA:BB:CC:DD:05:00"
        vcores                  = 4
        vram                    = 4096
        tags                    = "talos,controller"
        vmodel                  = "virtio"
        vnetwork                = "vmbr0"
        vnetwork_tag            = null
        additional_vnetwork     = "vmbr0"
        additional_vnetwork_tag = 20
      }
    },
    local.workers
  )
}
