locals {
  secret_vars = yamldecode(sops_decrypt_file("${get_repo_root()}/infrastructure/secrets.yaml"))

  # The LXC network config stores the CIDR (e.g. 192.0.2.10/24); the
  # backend needs the bare address.
  garage_host = split("/", local.secret_vars.network_config.garage_lxc.ip)[0]
}

remote_state {
  backend = "s3"
  config = {
    bucket   = "tofu-state"
    key      = "${basename(get_terragrunt_dir())}/terraform.tfstate"
    endpoint = "http://${local.garage_host}:3900"
    region   = "garage"

    access_key = local.secret_vars.garage.s3.access_key_id
    secret_key = local.secret_vars.garage.s3.secret_access_key

    use_lockfile     = true
    force_path_style = true

    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
  }
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
}
