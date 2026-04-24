# ADR-015: Kubernetes Disaster Recovery — Velero, etcd Snapshots, and CNPG Barman

## Status

Accepted

## Context

A running Kubernetes cluster has state in three distinct places, each requiring a different tool to back up and restore.

**Cluster state** covers the Kubernetes resource manifests describing what should run: Deployments, Services, ConfigMaps, Secrets, PVCs, CRDs, ArgoCD (see [ADR-003](ADR-003-argocd.md)) Applications, cert-manager Certificates, Longhorn (see [ADR-007](ADR-007-longhorn.md)) volumes, NetworkPolicies. Much of this lives in git, but not all of it.

**etcd** is the control plane's internal database. It holds the live cluster topology, lease records, and a linearisable snapshot of every API resource. It is not the same as the manifests in git. A corrupted or missing etcd cannot be recovered from git alone, and Velero cannot help when etcd is down because Velero depends on the API server.

**Application data** is the content written by running workloads: database rows, file uploads, config tables. It lives in PVCs and is captured by neither of the above.

On a single-host homelab the standard dismissal ("data is either recreatable or on RAID") doesn't hold for everything. Several pieces of state here are genuinely irreplaceable:

- Authentik's (see [ADR-008](ADR-008-authentik.md)) Postgres database holds users, MFA enrolments, OIDC client configs, and access policies. Losing it means re-enrolling every user and rebuilding every provider integration.
- CNPG (see [ADR-006](ADR-006-cloudnativepg.md)) clusters backing n8n and Paperless-ngx hold workflow history and document metadata with no other source of truth.
- The [cert-manager](https://cert-manager.io) ACME account registration secret (`letsencrypt-account-key`) is generated at ACME registration time and never stored in git. If it is lost during a rebuild and the domain has hit [Let's Encrypt](https://letsencrypt.org)'s wildcard rate limit (5 issuances per domain per week), production TLS stalls for up to a week. Every internal service is either unreachable or serving an invalid certificate until the limit resets.
- ArgoCD Applications, CNPG Cluster objects, and NetworkPolicies can be reproduced from git, but reproducing them correctly and in dependency order while debugging a post-disaster cluster is significantly harder than restoring from backup.

The goal is not zero-downtime resilience. The goal is to minimise recovery time and prevent permanent loss of data that cannot be recreated.

[Velero](https://velero.io) alone doesn't cover etcd or provide application-consistent database backups. A daily PVC snapshot of a live Postgres is crash-consistent at best and up to 24 hours stale. Barman's (see [ADR-006](ADR-006-cloudnativepg.md)) WAL archiving gives a recovery point objective of seconds to minutes, not hours, because it works with Postgres's own WAL mechanism rather than snapshotting the data directory mid-write. For the same reason, [Kasten K10](https://www.kasten.io) and [Stash](https://stash.run) were evaluated and rejected: they add licensing cost and operational complexity to achieve database consistency that Barman already provides natively within CNPG.

All three backup layers write to Garage (see [ADR-010](ADR-010-garage.md)), the self-hosted S3-compatible object store provisioned in [Phase 0.9](../../README.md#phases).

## Decision

I will use a three-layer backup strategy targeting Garage S3:

1. **[Velero](https://velero.io)** backs up all Kubernetes API resources and Longhorn PVC contents daily, with seven-day retention. The cert-manager namespace is explicitly included to preserve the ACME account secret. The `kube-system` namespace is excluded: Talos (see [ADR-001](ADR-001-kubernetes.md)) and [CoreDNS](https://coredns.io) are fully reproducible from git and the machine config, and including them adds size and restore complexity with no benefit.

2. **`talosctl etcd snapshot`** runs daily on the control plane node and uploads to Garage, retaining seven snapshots. This provides a restore path for the control plane that is independent of the API server, covering the narrow but consequential failure mode where etcd corruption prevents the API server from starting.

3. **CNPG Barman** provides continuous WAL archiving and periodic base backups for every CNPG-managed Postgres cluster. It is configured at cluster creation time, not added retroactively. On restore, creating the CNPG Cluster object triggers automatic Barman WAL recovery to the most recent consistent state.

On a full rebuild the restore sequence is: provision Talos, deploy Cilium (see [ADR-005](ADR-005-cilium-gateway-api.md)), bootstrap ArgoCD, deploy cert-manager, restore the cert-manager namespace from Velero (ACME secret first), deploy the CNPG operator, restore application namespaces (CNPG Cluster objects trigger Barman recovery automatically), then let ArgoCD reconcile the rest. The full sequence is in `docs/runbooks/cluster-rebuild.md`.

## Consequences

- Every CNPG cluster gets a Barman backup destination at creation time. This is enforced as a pattern in the `k8s-app` catalog module.
- cert-manager is never added to Velero exclusion lists, regardless of backup size growth.
- Velero restore is tested against a scratch cluster in [Phase 9](../../README.md#phases). Untested backups are not backups. The Recovery Time Objective (RTO) estimate of 4-8 hours is updated after that test.
- All three layers write to Garage on the same physical host. The backup strategy protects against software failure, accidental deletion, and cluster rebuilds. It does not protect against physical host loss. This risk is accepted until [Phase 15](../../README.md#phases) (offsite backup).
- Tier 1 NFS data (Immich photos, Paperless-ngx documents) is not covered by any of the three layers. btrfs RAID 1 covers single-drive failure; it does not cover host loss or accidental deletion. This is the sharpest known gap in the disaster recovery (DR) posture and is explicitly deferred to [Phase 15](../../README.md#phases), documented in [ADR-020](ADR-020-storage-tier-strategy.md).
- Garage does not support bucket versioning. A Velero backup that is overwritten or deleted is not recoverable from Garage itself. Periodic rclone snapshots of the Garage data directory mitigate this, as documented in [ADR-010](ADR-010-garage.md).
