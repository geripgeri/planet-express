locals {
  secret_vars = yamldecode(sops_decrypt_file(find_in_parent_folders("secrets.yaml")))
}

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}//infrastructure/catalogs/public/talos"
}

dependency "talos_vms" {
  config_path = "../../proxmox/talos-vms"
}

inputs = {
  talos_cluster_details = {
    name    = "talos-cluster-01"
    version = "v1.13.9"
    # K8s 1.35.8 is the latest 1.35 patch and the maximum supported by Talos
    # 1.12.x (support matrix talos.dev/v1.12/introduction/support-matrix).
    # Fresh VMs boot the 1.12-era ISO; applying K8s 1.36.x before the Talos
    # upgrade is rejected by the node with "version of Kubernetes 1.36.x is
    # too new to be used with Talos 1.12.4" (see docs/runbooks/talos-k8s-upgrade.md §2).
    # Two-phase rebuild required: keep K8s at 1.35.x while Talos upgrades to
    # 1.13.x, then bump K8s to 1.36.x in a second apply. Do not bump to
    # 1.37.x until Talos 1.14 is pinned (K8s 1.37 requires Talos 1.14).
    kubernetes_version = "1.35.8"
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

  # One-shot stack: talos_vms outputs static IPs (cidrhost vlan-10 30-33)
  # instead of qemu-guest-agent default_ipv4_address, so use dependency.
  controller_ips  = [dependency.talos_vms.outputs.ip_addresses["talos-controller-01"]]
  controller_vmid = 500

  workers = {
    talos-worker-01 = {
      ip   = dependency.talos_vms.outputs.ip_addresses["talos-worker-01"]
      vmid = 501
    }

    talos-worker-02 = {
      ip   = dependency.talos_vms.outputs.ip_addresses["talos-worker-02"]
      vmid = 502
    }

    talos-worker-03 = {
      ip   = dependency.talos_vms.outputs.ip_addresses["talos-worker-03"]
      vmid = 503
    }
  }
}
