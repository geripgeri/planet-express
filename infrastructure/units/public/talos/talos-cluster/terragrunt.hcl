locals {
  secret_vars = yamldecode(sops_decrypt_file(find_in_parent_folders("secrets.yaml")))

  # Shared Talos cluster identity + topology: cluster name, kubeconfig
  # context, controller/worker VMIDs (single source of truth).
  talos_base = read_terragrunt_config("${get_repo_root()}/infrastructure/units/public/talos/base.hcl")
}

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}//infrastructure/catalogs/public/talos"
}

inputs = {
  talos_cluster_details = {
    name    = local.talos_base.locals.cluster_name
    version = "v1.14.0"
    # K8s 1.37 is the default/maximum supported by Talos 1.14 (support matrix
    # talos.dev/v1.14/introduction/support-matrix). This was bumped in a second
    # apply after the Talos upgrade (renovate caps K8s < 1.38 until Talos 1.15,
    # see renovate.json5).
    kubernetes_version = "1.37.0"
    longhorn_disk_size = "100GB"
  }

  # Talos version the cluster was bootstrapped with (v1.12.4). NEVER change:
  # talos_machine_secrets regenerates when it does, rotating all cluster CAs
  # and locking out every talosconfig (x509 errors; recovery in
  # docs/runbooks/talos-k8s-upgrade.md §7).
  machine_secrets_version = "v1.12.4"

  # secrets.yaml's network_config also carries per-host entries (e.g.
  # garage_lxc: ip/gw); the catalog variable accepts VLAN maps only, so
  # select entries by their required attribute.
  network_config = {
    for name, cfg in local.secret_vars.network_config : name => cfg if can(cfg.subnet)
  }

  # IPs come from base.hcl (same cidrhost formula the talos-vms Terraform
  # module uses). The old dependency block on talos_vms fails in stack mode
  # because stack-run resolves dependencies via tofu output -json, which
  # needs providers cached in the dependency unit's .terragrunt-cache — but
  # the dependency unit hasn't been init'd yet.  Base.hcl is the single
  # source of truth for the whole cluster topology.
  controller_ips  = [local.talos_base.locals.controller_ip]
  controller_vmid = local.talos_base.locals.controller_vmid

  workers = {
    for name, ws in local.talos_base.locals.workers :
    name => {
      ip   = ws.ip
      vmid = ws.vmid
    }
  }
}
