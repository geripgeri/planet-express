locals {
  repo_root       = get_repo_root()
  secret_vars     = yamldecode(sops_decrypt_file("${local.repo_root}/infrastructure/secrets.yaml"))
  garage_api_host = split("/", local.secret_vars.network_config.garage_lxc.ip)[0]
}

include "root" {
  path = "${get_repo_root()}/infrastructure/root.hcl"
}

terraform {
  source = "${local.repo_root}//infrastructure/catalogs/public/garage"
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    provider "garage" {
      host   = "${local.garage_api_host}:3903"
      scheme = "http"
      token  = "${local.secret_vars.garage.admin_token}"
    }
  EOF
}

inputs = {
  create_bucket       = true
  bucket_global_alias = "k8s-backup"
  create_key          = true
  key_name            = "authentik-backup"
}
