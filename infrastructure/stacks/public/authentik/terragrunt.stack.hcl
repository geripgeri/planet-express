locals {
  repo_root = get_repo_root()
}

# Applied only after the Authentik stack is live and the admin API token is
# in secrets.yaml (docs/runbooks/authentik-deploy.md): the goauthentik
# provider cannot reach auth.peidl.net before the slice-1 HTTPRoute exists.
unit "authentik" {
  source = "${local.repo_root}/infrastructure/units/public/authentik"
  path   = "authentik"
}
