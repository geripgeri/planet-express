locals {
  secret_vars = yamldecode(sops_decrypt_file(find_in_parent_folders("secrets.yaml")))
}

remote_state {
  backend = "local"
  config = {
    path = "${get_repo_root()}/terraform.tfstate.d/${basename(get_terragrunt_dir())}/terraform.tfstate"
  }
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
}

inputs = merge(local.secret_vars, {})
