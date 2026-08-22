# Shared Proxmox guest config: provider auth, vlan-10 resolvers, template pin.
locals {
  proxmox_base = read_terragrunt_config("${get_repo_root()}/infrastructure/units/public/proxmox/base.hcl")
}

include "root" {
  path = find_in_parent_folders("root.hcl")
}

# Carries the shared provider generate block. Values are read through the
# local.proxmox_base handle above: include.<label>.locals resolves to null
# on some Terragrunt versions and must not be used.
include "proxmox_base" {
  path = "${get_repo_root()}/infrastructure/units/public/proxmox/base.hcl"
}

terraform {
  source = "${get_repo_root()}//infrastructure/catalogs/public/lxc"
}

inputs = {
  proxmox = local.proxmox_base.locals.secret_vars.proxmox

  container_details = {
    target_node     = local.proxmox_base.locals.secret_vars.proxmox.node_name
    ostemplate      = local.proxmox_base.locals.lxc_ostemplate
    storage         = "local-lvm"
    nameserver      = local.proxmox_base.locals.guest_nameservers
    unprivileged    = true
    ssh_public_keys = local.proxmox_base.locals.secret_vars.ssh_keys.lxc_admin
    start           = true
    onboot          = true
  }

  containers = {
    # Garage is the remote OpenTofu state backend (ADR-010); it is a hard
    # dependency and must be provisioned before any unit migrates state.
    # Its IP is static and lives in secrets.yaml because LXC resources expose
    # no provider-discovered address.
    garage-01 = {
      vmid      = 110
      cores     = 2
      memory    = 2048
      disk_size = "20G"
      network = {
        bridge = "vmbr0"
        ip     = local.proxmox_base.locals.secret_vars.network_config.garage_lxc.ip # CIDR address, or "dhcp"
        gw     = local.proxmox_base.locals.secret_vars.network_config.garage_lxc.gw
      }
      tags = "garage;storage"
    }
  }
}
