locals {
  worker_count = 3

  # Shared Proxmox guest config: provider auth, vlan-10 resolvers, template pin.
  proxmox_base = read_terragrunt_config("${get_repo_root()}/infrastructure/units/public/proxmox/base.hcl")

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

  workers = {
    for i in range(1, local.worker_count + 1) :
    format("talos-worker-%02d", i) => merge(local.worker_defaults, {
      vmid    = 500 + i
      macaddr = format("AA:BB:CC:DD:05:%02X", i)
    })
  }

  # Static IPs for one-shot stack: native bridge1 is DHCP but Talos IPs are
  # reserved via DHCP (controller 500->30, workers 501-503->31-33).
  # Use these for ip_addresses output instead of qemu-guest-agent
  # default_ipv4_address which is empty until Talos extension installs.
  vlan10_subnet = local.proxmox_base.locals.secret_vars.network_config.vlan-10.subnet
  static_ips = merge(
    { "talos-controller-01" = cidrhost(local.vlan10_subnet, 30) },
    { for k, v in local.workers : k => cidrhost(local.vlan10_subnet, v.vmid - 470) }
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
        vmid                    = 500
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
