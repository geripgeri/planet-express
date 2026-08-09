# Runbook: Talos + Kubernetes Upgrade

Upgrade the Talos cluster (Talos minor/patch + Kubernetes minor). Follow top-to-bottom.
Current example: v1.12.4 → v1.13.8, Kubernetes 1.35.0 → 1.36.2.

## Prerequisites

- Clean git tree on `main`, pinned versions in
  `infrastructure/units/public/talos/talos-cluster/terragrunt.hcl` (`version`,
  `kubernetes_version`)
- `tofu`, `terragrunt`, `talosctl`, `kubectl` available (tfswitch/tgswitch)
- Maintenance window; expected downtime: brief per-node service restarts,
  ArgoCD auth breakage (secrets regeneration)
- `talosctl etcd snapshot <path>` (see §4; ADR-015) before starting

## 1. Verify current state

```bash
kubectl get nodes -o wide
talosctl version
```

## 2. Update version pins

Talos minor and Kubernetes minor must land in **separate applies** (two
commits). This module applies the new machine config *before* running the
Talos upgrade, and a node still on the old Talos rejects configs whose
Kubernetes version is outside its support range
(e.g. `version of Kubernetes 1.36.2 is too new to be used with Talos 1.12.4`).

1. Phase 1 — bump only `version` (e.g. `v1.13.8`), keep `kubernetes_version`
   on the currently running release (e.g. `1.35.0`). Check the support
   matrix first: the old Talos must accept that Kubernetes version.
2. Apply, let nodes upgrade to the new Talos.
3. Phase 2 — bump `kubernetes_version` (e.g. `1.36.2`), apply again.

```bash
# edit infrastructure/units/public/talos/talos-cluster/terragrunt.hcl
# phase 1:
#   version            = "v1.13.8"
#   kubernetes_version = "1.35.0"     # unchanged, still accepted by old Talos
# phase 2 (after apply):
#   kubernetes_version = "1.36.2"
```

Commit + push + merge per phase (normal PR flow), then pull `main`.

## 3. Plan

```bash
cd infrastructure/units/public/proxmox/talos-vms
terragrunt plan          # expect: 0 add, 4 change (IP re-probe), 0 destroy

cd ../talos/talos-cluster
terragrunt plan          # expect: null_resource replaces (upgrade triggers),
                         # in-place: machine_secrets + kubeconfig + 4 config applies
```

Expected plan (sanity check):
- `-/+` only on `null_resource.*` (installer-image / config-hash triggers)
- `~` on `talos_machine_secrets`, `talos_cluster_kubeconfig`,
  `talos_machine_configuration_apply` ×4
- `talos_image_factory_schematic` NOT in plan (IDs are version-independent)

## 4. Snapshot etcd (before apply)

```bash
talosctl -n <controller-ip> etcd snapshot /tmp/etcd-before-upgrade.snapshot
```

## 5. Apply

```bash
# 5a. talos-vms first (settles IP outputs the cluster unit reads)
cd infrastructure/units/public/proxmox/talos-vms
terragrunt apply

# 5b. talos-cluster (applies new machine config, runs talosctl upgrade on all nodes)
cd infrastructure/units/public/talos/talos-cluster
terragrunt apply
```

Known issue: the first apply may abort with

```
Error: Provider produced inconsistent final plan
... invalid new value for .machine_configuration_hash: was ... but now ...
```

This happens when machine secrets rotate in the same apply: the machine
config data sources are read during apply, so the provider planned a stale
`machine_configuration_hash` and OpenTofu rejects the recomputed one.
State has advanced past the conflict — just re-run `terragrunt apply`
(second run plans with the new secrets and succeeds).
Upstream: siderolabs/terraform-provider-talos#352, fixed in provider 0.12.x
(not in 0.11.0 which this module pins).

Notes:
- Apply order is sequential per resource; nodes upgrade via
  `null_resource.upgrade_*` (`talosctl upgrade --wait=false`)
- Machine secrets regenerate → new CA/SA signing key; kubeconfig/talosconfig
  rewritten to `~/.kube` / `~/.talos`

## 6. Post-upgrade verification

```bash
kubectl get nodes -o wide            # all v1.36.2, Ready
kubectl get pods -A | grep -v Running | grep -v Completed   # nothing stuck
talosctl -n <controller-ip> version  # v1.13.8

# ArgoCD auth (SA token invalidated by new signing key)
kubectl -n argocd rollout restart deployment/argocd-server
kubectl -n argocd rollout status deployment/argocd-server
# check apps sync
kubectl -n argocd get applications
```

## 7. If upgrade fails / cluster unhealthy

```bash
# Revert: roll back version pins, plan, apply (machine config reverts; Talos
# does not auto-downgrade — downgrade requires reinstall from installer image)
# Quick health checks:
kubectl get nodes                      # NotReady?
talosctl -n <controller-ip> get machinestatus
talosctl -n <controller-ip> etcd status
# Recovering a broken control plane node: reimage from installer image and
# let it rejoin (etcd re-bootstraps; no talosctl etcd restore — talosctl has
# no restore command, snapshots are archival/inspection only)
# Full recovery: docs/runbooks/cluster-rebuild.md (GAP: not yet written)
```

## 8. Update docs

- `docs/install.md` / README if they mention the old versions (grep
  `1.35.0` / `v1.12.4`; none expected)
