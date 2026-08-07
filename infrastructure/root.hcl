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
