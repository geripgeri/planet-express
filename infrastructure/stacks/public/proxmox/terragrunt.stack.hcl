locals {
  repo_root = get_repo_root()
}

# Generated unit paths mirror the units/public tree layout, so relative
# dependency config_path values (e.g. talos-cluster's ../../proxmox/talos-vms)
# keep resolving inside .terragrunt-stack/ after generation.
unit "talos_vms" {
  source = "${local.repo_root}/infrastructure/units/public/proxmox/talos-vms"
  path   = "proxmox/talos-vms"
}

unit "talos_cluster" {
  source = "${local.repo_root}/infrastructure/units/public/talos/talos-cluster"
  path   = "talos/talos-cluster"
}

# Cilium CNI must be Ready before any workload pods schedule.
# Talos has cni: none, nodes stay NotReady/NoSchedule until DaemonSet
# runs (ADR-005, incident 2026-08-29). Keep it in the bootstrap stack
# with talos_cluster so `stack run` in proxmox provisions VMs -> Talos -> CNI
# in one DAG; ArgoCD stack then assumes Ready nodes.
unit "cilium" {
  source = "${local.repo_root}/infrastructure/units/public/cilium"
  path   = "cilium"
}

# Garage LXC is applied only after its Ansible guest setup ran
# (docs/runbooks/garage-lxc-setup.md); the garage stack units fail cleanly
# while the admin API is unreachable, which is the actual ordering guard.
unit "garage_lxc" {
  source = "${local.repo_root}/infrastructure/units/public/proxmox/garage-lxc"
  path   = "proxmox/garage-lxc"
}
