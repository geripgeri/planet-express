# ADR-010: Garage S3 on Proxmox LXC as Remote OpenTofu State Backend

## Status

Accepted

## Context

OpenTofu (see [ADR-002](ADR-002-opentofu-terragrunt.md)) state is stored in local files, one per unit. As the homelab grows, local state means no locking, no shared access, and state files tied to a single machine, all of which a remote S3-compatible backend solves. [Garage](https://garagehq.deuxfleurs.fr/) is a self-hosted, lightweight S3-compatible object store designed for small clusters, which fits the constraint of avoiding external dependencies for core infrastructure.

Garage must be available before any unit migrates state to it, and that creates a bootstrapping constraint: Garage cannot be managed by a unit that depends on it. Hosting Garage inside Kubernetes would introduce a circular dependency, because the cluster is itself provisioned by OpenTofu, and it would tie core storage availability to the health of the cluster scheduler.

## Decision

I will run Garage as a Proxmox LXC container and configure it as the S3 backend for all OpenTofu state. State migrates unit by unit from local files as the Garage LXC is provisioned and confirmed stable, not in a single cutover.

## Consequences

- State locking and remote storage are available for all units once Garage is live
- Garage on LXC is independent of Kubernetes, which removes the circular dependency between cluster provisioning and state storage
- Incremental migration lowers risk: each unit moves and verifies individually, with local state as fallback until migration completes
- The Garage LXC is a hard dependency and must be provisioned before other units migrate. Its own state bootstrap needs care (local state or a separately maintained state file)
- One more LXC to operate, monitor, and back up
- Garage is less mature than MinIO or AWS S3, so some S3 API edge cases may surface

Amendment (2026-08-22): migration completed uniformly, bootstrap units included. The `proxmox/garage-lxc` and `garage/tofu-state` units moved to the same backend they provision. That trades the bootstrap circularity concern above against single-backend simplicity, and it is acceptable because recovery starts from a restored bucket rather than local files. The planned off-site backup of the bucket contents is not deployed yet, so until it lands recovery relies on the host-local `terraform.tfstate.d/` copies and RPO equals their age (migration runbook §7). Once the repo-managed backup deploys, restore-first becomes the primary recovery path per [ADR-015](ADR-015-disaster-recovery.md) and the bootstrap caveat fully retires.

Amendment (2026-09-25): application backups use a separate `k8s-backup` bucket and `authentik-backup` Garage key, and the `tofu-state` key stays limited to the state bucket. The `garage/k8s-backup` Terragrunt unit manages the dedicated key, which gets copied into SOPS after apply and injected into the CNPG backup Secret by the bootstrap script. That preserves least-privilege access between state management and application backup workloads.
