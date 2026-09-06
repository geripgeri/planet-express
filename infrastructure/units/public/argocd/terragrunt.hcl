locals {
  secret_vars = yamldecode(sops_decrypt_file(find_in_parent_folders("secrets.yaml")))
}

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}//infrastructure/catalogs/public/k8s-app"
}

# Cilium is now in the proxmox bootstrap stack (cni: none -> NotReady).
# ArgoCD assumes nodes are Ready; run proxmox stack (talos + cilium) first,
# then argocd stack. No terragrunt dependency needed across stacks.

# Cluster credentials come from the local kubeconfig written by talosctl.
generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    provider "helm" {
      kubernetes = {
        config_path    = "~/.kube/config"
        config_context = "admin@talos-cluster-01"
      }
    }

    provider "kubernetes" {
      config_path    = "~/.kube/config"
      config_context = "admin@talos-cluster-01"
    }

    provider "kubectl" {
      config_path    = "~/.kube/config"
      config_context = "admin@talos-cluster-01"
    }
  EOF
}

inputs = {
  gitea = local.secret_vars.gitea

  dns01_api_token = local.secret_vars.dns_provider.api_token

  # Export SOPS_AGE_KEY before applying to also bootstrap the in-cluster
  # key Secret; leaving it unset skips that resource.
  sops_age_key = get_env("SOPS_AGE_KEY", "")
}
