# ADR-007: Longhorn with a Two-StorageClass Strategy on Talos Kubernetes

## Status

Active

## Context

The Talos (see [ADR-001](ADR-001-kubernetes.md)) cluster has three worker nodes, each backed by a slice of a Samsung 990 PRO NVMe. Stateful workloads need PersistentVolumes. The question is which CSI driver, which replication model, and whether one StorageClass is enough or whether different data classes warrant different behaviour.

Persistent storage needs fall into two categories with meaningfully different durability profiles:

**Irreplaceable data**: CNPG (see [ADR-006](ADR-006-cloudnativepg.md)) database volumes for Authentik (see [ADR-008](ADR-008-authentik.md)), application databases, anything where loss means real work is gone and restoration requires a backup chain. This warrants genuine cross-node replication so a single worker failure does not cause data loss or extended unavailability.

**Reproducible or ephemeral data**: [Prometheus](https://prometheus.io/) metrics history, [Loki](https://grafana.com/oss/loki/) log aggregations, Grafana (see [ADR-011](ADR-011-observability.md)) dashboards, [Alertmanager](https://prometheus.io/docs/alerting/latest/alertmanager/) state, Redis caches. These repopulate quickly (scraping restores Prometheus within minutes), recover from upstream sources (logs can be re-shipped; dashboards are in git), or are genuinely ephemeral. Replicating this data three times wastes NVMe capacity for insurance that is rarely needed and quickly recoverable without it.

A single StorageClass forces a choice between over-replicating ephemeral data or under-protecting irreplaceable data.

**Why Longhorn:** The 3-worker topology makes cross-node replication meaningful. With one replica per worker node, a worker going down for maintenance, a kernel panic, or a failed kubelet does not take the volume offline. Pods reschedule and resume from replicated state without manual intervention.

[Longhorn](https://longhorn.io) on Talos has non-trivial setup requirements: udev rules, kernel modules (`dm_crypt`, `iscsi_tcp`), and kubelet extra mounts for the CSI socket path. All of this is resolved; the Talos machine config patches are committed and Longhorn is running stable. This matters when weighing alternatives, since setup cost for any replacement starts from zero.

Alternatives considered:

- **hostPath / [local-path-provisioner](https://github.com/rancher/local-path-provisioner)**: rejected. Volumes are pinned to a single node and cannot survive a node failure or reschedule, which is the core problem being solved.
- **[Rook/Ceph](https://rook.io)**: rejected on resource footprint. Ceph requires a minimum of 3 OSDs and significant per-daemon RAM overhead that competes directly with application workloads on the same nodes. It's the right answer for a dedicated storage cluster, not for a homelab where storage and compute share the same VMs.
- **[OpenEBS/Mayastor](https://openebs.io)**: not evaluated in depth. Kernel module requirements on Talos are similar to Longhorn's, and the operational ecosystem for this platform combination is thinner. Longhorn is already running; there is no basis for migration.
- **NFS for all storage including databases**: rejected for CNPG volumes. PostgreSQL expects POSIX-compliant fsync behaviour; NFS implementations vary in how they handle this, and performance under write-heavy workloads degrades significantly. CNPG clusters belong on local block storage, not NFS.

NFS-backed PVCs (Immich, [Jellyfin](https://jellyfin.org), Paperless-ngx (see [ADR-006](ADR-006-cloudnativepg.md))) are outside Longhorn's scope. They are provisioned via the [NFS CSI driver](https://github.com/kubernetes-csi/csi-driver-nfs) against the NFS LXC, with durability from [btrfs](https://btrfs.readthedocs.io) Redundant Array of Independent Disks (RAID 1) at the storage tier. This separation is deliberate: host-level storage is managed outside Kubernetes because its lifecycle is independent of the cluster.

## Decision

I will use [Longhorn](https://longhorn.io) as the CSI driver for all Kubernetes block storage on Tier 0 (the NVMe), deployed as an ArgoCD (see [ADR-003](ADR-003-argocd.md)) Helm release with Renovate (see [ADR-004](ADR-004-renovate.md)) watching for chart updates. Two StorageClasses are deployed:

```yaml
# longhorn — 3 replicas (default)
# For: app databases, CNPG clusters, anything irreplaceable
parameters:
  numberOfReplicas: "3"
# longhorn-single-replica — 1 replica
# For: Prometheus, Loki, Grafana, Alertmanager, Redis, reproducible or ephemeral data
parameters:
  numberOfReplicas: "1"
  dataLocality: "disabled"
```

The rule: when in doubt, use `longhorn` (3 replicas). `longhorn-single-replica` is for data that is truly ephemeral or reproducible.

For CNPG specifically: irreplaceable databases (Authentik, user-facing application databases) always use `longhorn`. CNPG clusters that are genuinely recreatable from scratch (n8n workflow history, scratch data with no user impact) may use `longhorn-single-replica`. The identity store and primary user-facing databases do not qualify as recreatable.

## Consequences

**Positive:**

- A worker node going offline does not cause data loss for 3-replica volumes; pods reschedule and resume without manual intervention
- NVMe capacity is explicitly managed: 3-replica for irreplaceable data, 1-replica for ephemeral, with a clear default of 3 replicas to prevent accidental under-protection
- Longhorn is a standard ArgoCD Application; its Prometheus metrics endpoint and Grafana dashboard surface volume health in the same observability stack as everything else
- No ad-hoc `hostPath` usage; all stateful workloads use one of two defined StorageClasses

**Negative / trade-offs:**

- Observability tooling on `longhorn-single-replica` cannot survive a worker node failure without the pod waiting for the node to return or the volume being manually relocated; this is an accepted trade-off given the fast recovery path for reproducible data
- 3-replica volumes consume approximately 3 GB of raw NVMe per 1 GB of PVC capacity across the three workers, all on the same physical Samsung 990 PRO; the single-replica class exists specifically to keep observability tooling from consuming NVMe budget reserved for databases
