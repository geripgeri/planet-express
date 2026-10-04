# ADR-006: CloudNativePG as the Kubernetes Postgres Operator

## Status

Active

## Context

Several services in this stack need a relational database: Authentik (see [ADR-008](ADR-008-authentik.md)) (users, Multi-Factor Authentication (MFA) tokens, OpenID Connect (OIDC) providers), n8n (workflow definitions and execution history), Immich (photo metadata and ML embedding vectors), and [Paperless-ngx](https://docs.paperless-ngx.com/) (document index and OCR results). In Docker Compose each ran its own Postgres container with no backup automation and no replication.

Running the official Postgres image as a bare StatefulSet is possible but wrong for this data. Without Write-Ahead Log (WAL) archiving a Postgres instance can lose transactions on unclean shutdown. Without a standby it has no recovery path on node failure without downtime. Without lifecycle management every version upgrade is a manual operation. None of that is acceptable for an identity provider, a photo library, or a document archive, so a Postgres operator was needed. The open question was which one.

Three candidates were evaluated.

**[Zalando Postgres Operator](https://github.com/zalando/postgres-operator)** manages Postgres through [Patroni](https://github.com/patroni/patroni), adding an abstraction layer between the operator and Postgres that increases the surface area to debug. Backup support ([WAL-G](https://github.com/wal-g/wal-g), [WAL-E](https://github.com/wal-e/wal-e)) is functional but more manual than CNPG's native Barman integration. No CNCF affiliation.

**[Crunchy Data PGO](https://github.com/CrunchyData/postgres-operator)** is well-engineered and reflects deep Postgres expertise. Its multi-CRD model (`PostgresCluster`, `PostgresUser`, `PostgresDatabase`) offers more granular control than CNPG, but adds cognitive overhead for a homelab running 5-10 clusters. No CNCF affiliation.

**Plain StatefulSet / [Bitnami](https://bitnami.com/) chart** were rejected early. A StatefulSet gives a running Postgres process and a PVC, and everything the operator provides becomes custom automation owned forever. The Bitnami chart wraps a StatefulSet with some configuration options, but it is not an operator and does not handle WAL archiving, automated failover, or Prometheus Operator integration.

## Decision

I will use [CloudNativePG](https://cloudnative-pg.io/) (CNPG) as the Kubernetes Postgres operator for all relational database workloads in this stack.

Each application that needs Postgres gets its own dedicated CNPG `Cluster` resource. No Postgres is shared between applications. Every cluster has [Barman](https://pgbarman.org/) WAL archiving configured at creation time, pointing at the Garage (see [ADR-010](ADR-010-garage.md)) S3 bucket provisioned in [Phase 0.9](../../README.md#phases).

StorageClass assignment follows a fixed rule based on recoverability:

| Application   | StorageClass              | Rationale                                                                                      |
| ------------- | ------------------------- | ---------------------------------------------------------------------------------------------- |
| Authentik     | `longhorn` (3 replicas)   | Identity data is irreplaceable without manual account reconstruction.                          |
| Immich        | `longhorn` (3 replicas)   | Metadata loss means re-indexing the full library; vector re-embedding is CPU-intensive.        |
| Paperless-ngx | `longhorn` (3 replicas)   | Index loss means re-OCR processing all documents.                                              |
| n8n           | `longhorn-single-replica` | Workflow definitions are in git. Execution history is inconvenient, not catastrophic, to lose. |

`longhorn-single-replica` is for data you would not hesitate to delete if you needed the space, not a general cost optimisation.

**Why CNPG specifically:**

CNPG was donated to CNCF by [EDB](https://www.enterprisedb.com/) in 2023 and accepted at Sandbox level. CNCF governance means the project cannot be relicensed or abandoned without community consensus, and for infrastructure handling identity data and photo archives, operator longevity matters.

CNPG integrates Barman natively: backup configuration is part of the `Cluster` manifest rather than a separate sidecar or external job. Garage, already the S3 backend for OpenTofu (see [ADR-002](ADR-002-opentofu-terragrunt.md)) state and Velero (see [ADR-015](ADR-015-disaster-recovery.md)), is a valid Barman target with a standard endpoint override.

The `Pooler` CRD deploys [PgBouncer](https://www.pgbouncer.org/) in front of a cluster, managed by the same operator that manages the cluster. For applications that open many short-lived connections (Authentik, n8n), connection pooling is not optional.

CNPG creates two Kubernetes Services per cluster automatically: one pointing at the current primary for writes, one pointing at all instances for read-only workloads. The operator updates service endpoints on failover, so applications need no reconfiguration.

CNPG exposes a [Prometheus](https://prometheus.io/) endpoint on each instance out of the box. Setting `enablePodMonitor: true` in the `Cluster` manifest creates a `PodMonitor` resource automatically, so no separate exporter sidecar is needed.

Per-app clusters are the operationally correct choice here. Schema evolution for one application cannot affect another. If Authentik's database is corrupted, the recovery operation is "restore Authentik's cluster from Barman": the restore unit is the application. Failure blast radius stays contained, because a long-running query in one database cannot saturate connection limits or hold locks visible to another application. Capacity is sized per workload, which matters as Immich grows the photo library.

Longhorn (see [ADR-007](ADR-007-longhorn.md)) replication and Barman backup are complementary, not substitutes. Longhorn gives redundancy against node failure; Barman gives point-in-time recovery and protection against logical data corruption. Both layers are necessary.

## Consequences

- Every application requiring Postgres has a dedicated CNPG `Cluster` committed to git. No shared Postgres, no ad-hoc `kubectl exec psql`.
- Barman backup to Garage S3 is configured at cluster creation, so there is no window where a cluster exists without backup coverage.
- CNPG metrics are scraped by Prometheus via `PodMonitor` automatically. Postgres-level metrics (connection counts, replication lag, vacuum state) show up in Grafana (see [ADR-011](ADR-011-observability.md)) without an extra exporter.
- The Velero cluster backup covers CNPG `Cluster` CRDs and associated Secrets. With Barman WAL archiving, that gives two independent recovery paths per database.
- Renovate (see [ADR-004](ADR-004-renovate.md)) tracks CNPG version bumps across both the operator Helm chart and the `imageName` fields in each `Cluster` manifest.
- CNCF governance mitigates operator longevity risk. The worst-case exit path is a community fork, not silent abandonment.
- Per-app clusters carry higher resource overhead than a shared cluster. On this hardware the overhead is acceptable and the isolation benefits justify it.
