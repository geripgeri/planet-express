locals {
  secret_vars = yamldecode(sops_decrypt_file(find_in_parent_folders("secrets.yaml")))
}

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}//infrastructure/catalogs/public/authentik-app"
}

# goauthentik provider talks to the in-cluster Authentik instance exposed
# only after the slice-1 HTTPRoute lands; apply order is in
# docs/runbooks/authentik-deploy.md.
generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    provider "authentik" {
      url   = "${local.secret_vars.authentik.url}"
      token = "${local.secret_vars.authentik.api_token}"
    }
  EOF
}

inputs = {
  authentik_url       = local.secret_vars.authentik.url
  argocd_callback_url = local.secret_vars.authentik.argocd_callback_url
}
