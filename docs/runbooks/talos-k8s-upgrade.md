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
- `talosctl etcd snapshot <path>` (see §4; [ADR-015](../decisions/ADR-015-disaster-recovery.md)) before starting

## 1. Back up and verify current state

Machine secrets must survive this upgrade unchanged — they are pinned by
`machine_secrets_version` (see §7). Back everything up first; if the state
file or the talosconfig is lost, the cluster is unrecoverable without a
rebuild.

```bash
# 1. Terraform state (contains all cluster CAs and admin keys). Lives in
#    Garage S3 now; pull a local copy out of the backend:
mkdir -p /tmp/tfstate-backup-$(date +%s)
cd infrastructure/units/public/talos/talos-cluster
terragrunt state pull > /tmp/tfstate-backup-$(date +%s)/talos-cluster.tfstate
cd -

# 2. talosconfig (root access; mirror the dated-copy convention in ~/.talos)
cp -a ~/.talos/talos-cluster-01.yaml ~/.talos/talos-cluster-01-$(date +%Y%m%d).yaml
sha256sum ~/.talos/talos-cluster-01*.yaml | tee /tmp/talosconfig-sha256.txt

# 3. Optional but recommended: Proxmox VM snapshot (fast, zero downtime,
#    rollback point for every node). Works with qcow2/ZFS/LVM-thin storage.
for vmid in <controller-vmid> <worker-vmids...>; do
  qm snapshot $vmid upgrade-pre-$(date +%Y%m%d)
done
# Full VM backup instead of snapshot (slower, movable off-host):
#   vzdump <vmid> --mode snapshot --compress zstd --notes-template "pre-upgrade {{guestname}}"
```

Then verify current state:

```bash
kubectl get nodes -o wide
talosctl version
```

Sanity: `talosctl -n <controller-ip> version` must succeed — if it fails
with x509 errors the machine secrets were already rotated or the talosconfig
is gone; see §7 before touching anything.

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
- `~` on `talos_cluster_kubeconfig`, `talos_machine_configuration_apply` ×4
- `talos_machine_secrets` NOT in plan (version pinned to bootstrap; secrets
  never regenerate — if it appears, `machine_secrets_version` was bumped)
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
Upstream: siderolabs/terraform-provider-talos#352, fixed on the provider
0.12.0 line (alpha releases only; no stable 0.12.x yet). With
`machine_secrets_version` pinned this no longer occurs in normal upgrades.

Notes:

- `talosctl upgrade` blocks until the node reboots and reports the new
  version, so apply order is sequential per resource — each node upgrades
  and comes back before the next starts, and failures surface in the apply.

- The final `null_resource.verify_upgrade` still re-checks every node's
  Talos and Kubernetes version and fails the apply if any node is stale —
  a belt-and-braces guard against partial installs or k8s rollouts. It
  probes the plain-text `talosctl version` output (the JSON form has no
  `server.tag` key and `-o json` is not a valid flag) and prints the raw
  talosctl output if a node never converges, so probe failures fail loudly
  instead of silently.

- For any node that still fails to upgrade, re-run its upgrade manually
  (workers first, controller last), with the installer image from the plan:

  ```bash
  talosctl -n <ip> upgrade \
    --image factory.talos.dev/metal-installer/<schematic-id>:<version>
  ```

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

### Machine secrets rotated / TLS lockout (x509 errors)

Symptom: `talos_machine_configuration_apply` fails on every node with
`x509: certificate signed by unknown authority ... candidate authority certificate "talos"`. Cause: `talos_machine_secrets` was regenerated (its
`talos_version` changed — this module pins it via `machine_secrets_version`,
see `infrastructure/catalogs/public/talos/main.tf`), so the provider's
client certs are signed by a new CA while the nodes still present the
original one.

Recovery (state surgery, no cluster impact; nodes stay untouched):

1. Confirm a pre-rotation talosconfig still works against the cluster
   (dated copies in `~/.talos`, e.g. the bootstrap-era one):
   ```bash
   TALOSCONFIG=~/.talos/talos-cluster-01-<date>.yaml talosctl -n <ip> version
   ```
   No working talosconfig left? Extract the original `machine.ca` cert+key
   from any node's STATE partition (mount via `qm` disk attach / vzdump
   archive / rescue ISO) and mint a client cert from the CA key with
   openssl, then build the talosconfig manually.
2. Dump the original config from the controller (contains all CA keys):
   ```bash
   export TALOSCONFIG=~/.talos/talos-cluster-01-<date>.yaml
   talosctl -n <controller-ip> get machineconfig v1alpha1 \
     -o jsonpath='{.spec}' > /tmp/orig-mc.yaml
   ```
3. Restore the original secrets into the state file. Pull the state from
   the Garage S3 backend, patch it locally, push it back:
   ```bash
   cd infrastructure/units/public/talos/talos-cluster
   terragrunt state pull > /tmp/talos-cluster.tfstate
   uv run python scripts/restore_machine_secrets.py \
     --state /tmp/talos-cluster.tfstate \
     --machine-config /tmp/orig-mc.yaml \
     --talosconfig ~/.talos/talos-cluster-01-<date>.yaml
   ```
   (writes a `.pre-restore.bak` copy next to the pulled file; prints only
   lengths and checksums — the file contains cluster root credentials,
   keep it local)
4. Push the patched state back, then converge:
   ```bash
   tofu state push /tmp/talos-cluster.tfstate
   terragrunt plan   # talos_machine_secrets must show no changes
   terragrunt apply
   rm /tmp/talos-cluster.tfstate
   ```
   `state push` refuses on serial mismatch; the pulled file has the latest
   serial, so retry only makes sense after re-pulling.

Afterwards: delete the dumped config (`rm /tmp/orig-mc.yaml` — full CA
keys), keep the talosconfig dated copies and state backups until the
upgrade is complete.

## 8. Update docs

- `docs/install.md` / README if they mention the old versions (grep
  `1.35.0` / `v1.12.4`; none expected)
