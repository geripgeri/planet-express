# Shared configuration for Proxmox guest units (LXC containers and VMs):
# provider auth, VLAN-10 resolver list, and the Debian LXC template pin.
# Use it from a unit:
#
#   include "proxmox_base" {
#     path = "${get_repo_root()}/infrastructure/units/public/proxmox/base.hcl"
#   }
#
#   locals {
#     proxmox_base = read_terragrunt_config("${get_repo_root()}/infrastructure/units/public/proxmox/base.hcl")
#   }
#
# The include carries the provider generate block below. Read values through
# the read_terragrunt_config handle: include.<label>.locals resolves to null
# on some Terragrunt versions and must not be used.

locals {
  secret_vars = yamldecode(sops_decrypt_file(find_in_parent_folders("secrets.yaml")))

  # Source of truth for the Debian LXC template is the proxmox_base Ansible
  # role default — that role owns `pveam download` on the host. Renovate
  # updates the single pinned line there; OpenTofu reads it at plan time,
  # so both sides cannot drift.
  lxc_ostemplate = "local:vztmpl/${yamldecode(file("${get_repo_root()}/ansible/roles/proxmox_base/defaults/main.yaml")).proxmox_base_pveam_template}"

  # DNS servers for guest network config (vlan-10 public resolvers).
  guest_nameservers = join(" ", local.secret_vars.network_config.vlan-10.public-nameservers-only)

  # The Proxmox API runs on a self-signed cert until it is replaced with a
  # proper one. Flip this to false once a trusted cert is in place.
  proxmox_tls_insecure = true
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
provider "proxmox" {
  pm_api_url          = var.proxmox.api_url
  pm_api_token_id     = var.proxmox.api_token_id
  pm_api_token_secret = var.proxmox.api_token_secret
  pm_tls_insecure     = ${local.proxmox_tls_insecure}
}
EOF
}
