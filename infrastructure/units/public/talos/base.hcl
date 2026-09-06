# Shared Talos cluster identity and VM topology (single source of truth).
# Consumed by every unit that provisions or targets the Talos cluster:
# proxmox/talos-vms (VMs + static IPs), talos/talos-cluster (bootstrap),
# and cilium (CNI). This keeps one authoritative definition of the cluster
# name, kubeconfig context, and controller/worker vmid+IP mapping instead
# of each unit re-deriving it.
#
# Read it from a unit:
#
#   locals {
#     talos_base = read_terragrunt_config("${get_repo_root()}/infrastructure/units/public/talos/base.hcl")
#   }
#
# Read values through the read_terragrunt_config handle:
# include.<label>.locals resolves to null on some Terragrunt versions and
# must not be used. There is no shared provider block here (the consuming
# units use different providers: proxmox, talos, helm/kubernetes), so this
# file carries no `include`/generate block.

locals {
  secret_vars = yamldecode(sops_decrypt_file(find_in_parent_folders("secrets.yaml")))

  # Cluster identity. kubeconfig context is derived so it cannot drift from
  # the cluster name.
  cluster_name = "talos-cluster-01"
  k8s_context  = "admin@${local.cluster_name}"

  # VM topology. Controller is the VMID base; workers offset from it.
  # Static IPs derive from VMID via the vlan-10 subnet (controller .30,
  # worker N -> .30+N, i.e. vmid - 470). One place owns the mapping so the
  # proxy-vm unit and the talos cluster cannot disagree on controller/worker
  # addresses (incident 2026-08-29: empty ip_addresses from a missing guest
  # agent; the fix passed static reservations through outputs).
  controller_vmid = 500
  worker_count    = 3

  vlan10_subnet = local.secret_vars.network_config.vlan-10.subnet

  controller_ip = cidrhost(local.vlan10_subnet, 30)

  workers = {
    for i in range(1, local.worker_count + 1) :
    format("talos-worker-%02d", i) => {
      vmid = local.controller_vmid + i
      ip   = cidrhost(local.vlan10_subnet, 30 + i)
    }
  }
}
