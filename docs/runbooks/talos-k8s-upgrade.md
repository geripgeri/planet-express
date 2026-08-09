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

```bash
# edit infrastructure/units/public/talos/talos-cluster/terragrunt.hcl
#   version            = "v1.13.8"
#   kubernetes_version = "1.36.2"
```

Commit + push + merge (normal PR flow), then pull `main`.

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
