locals {
  secret_vars = yamldecode(sops_decrypt_file(find_in_parent_folders("secrets.yaml")))
  # The LXC network config stores the CIDR (e.g. 192.0.2.10/24); the
  # garage provider needs the bare address.
  garage_api_host = split("/", local.secret_vars.network_config.garage_lxc.ip)[0]
}

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}//infrastructure/catalogs/public/garage"
}

# The garage provider talks to the Garage admin API on the LXC (port 3903).
# The admin token is the shared secret created during guest setup
# (docs/runbooks/garage-lxc-setup.md).
generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
provider "garage" {
  host   = "${local.garage_api_host}:3903"
  scheme = "http"
  token  = "${local.secret_vars.garage.admin_token}"
}
EOF
}

inputs = {
  create_bucket       = true
  bucket_global_alias = "tofu-state"
  create_key          = true
  key_name            = "tofu-state"
}
