locals {
  secret_vars = yamldecode(sops_decrypt_file(find_in_parent_folders("secrets.yaml")))

  # Private network topology (export-ignored, ADR-021). Keeps internal
  # addresses like the native routing CIDR out of public-mirrored paths.
  private_network = read_terragrunt_config(
    "${get_repo_root()}/infrastructure/units/private/cilium-network.hcl"
  )

  # Static controller IP matches proxmox/talos-vms static_ips logic
  # (cidrhost vlan-10 subnet, .30 for controller). Avoids cross-stack
  # dependency on talos_vms outputs which breaks stack generation when
  # cilium lives in a different stack (argocd vs proxmox).
  vlan10_subnet = local.secret_vars.network_config.vlan-10.subnet
  controller_ip = try(
    local.secret_vars.cilium.k8s_service_host,
    cidrhost(local.vlan10_subnet, 30)
  )
}

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}//infrastructure/catalogs/public/cilium"
}

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
  EOF
}

inputs = {
  # Cilium chart pin — public single source, Renovate bumps via custom regex
  # on infrastructure/catalogs/public/cilium/vars.tf and this file.
  cilium_version = "1.17.6"

  # API server host for Cilium k8sServiceHost. Talos cni is none, so Cilium
  # must know the controller IP directly (kubePrism 7445 is not the API).
  # Derived from secrets network_config like talos-vms static_ips, so the
  # unit is stack-independent.
  k8s_service_host = local.controller_ip

  # Native routing CIDR lives in the export-ignored private config
  # (ADR-021), so the public mirror never publishes internal addresses.
  native_routing_cidr = local.private_network.locals.native_routing_cidr

  helm_values_override = try(local.secret_vars.cilium.helm_values, {})
}
