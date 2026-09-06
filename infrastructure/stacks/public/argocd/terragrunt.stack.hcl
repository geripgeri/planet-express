locals {
  repo_root = get_repo_root()
}

unit "argocd" {
  source = "${local.repo_root}/infrastructure/units/public/argocd"
  path   = "argocd"
}
