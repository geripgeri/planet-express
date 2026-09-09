locals {
  # Shared Talos cluster identity (single source of truth, see talos/base.hcl).
  talos_base = read_terragrunt_config("${get_repo_root()}/infrastructure/units/public/talos/base.hcl")
}

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}//infrastructure/catalogs/public/ci-plan"
}

# Host-applied only (runbook: CI plan identity). The apply runs with the
# host's talosctl admin kubeconfig; this unit provisions the read-only
# credentials the CI workflow later uses to plan the argocd stack. It must
# stay OUTSIDE any stack: the plan loop has no cluster access until this
# exists, and giving the runner the rights to re-apply it is its own
# escalation vector.
generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    provider "kubernetes" {
      config_path    = "~/.kube/config"
      config_context = "${local.talos_base.locals.k8s_context}"
    }
  EOF
}

inputs = {
  # Single controlplane; the kube-apiserver listens on 6443 (Talos default).
  # Override with a VIP or load balancer here if the topology grows one.
  api_server = "https://${local.talos_base.locals.controller_ip}:6443"
}
