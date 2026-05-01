locals {
  repo_root = get_repo_root()
}

unit "talos_vms" {
  source = "${local.repo_root}/infrastructure/units/public/proxmox/talos-vms"
  path   = "talos-vms"
}

unit "talos_cluster" {
  source = "${local.repo_root}/infrastructure/units/public/talos/talos-cluster"
  path   = "talos-cluster"
}
