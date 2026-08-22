# ADR-010: Garage S3 on Proxmox LXC as Remote OpenTofu State Backend

## Status

Accepted

## Context

OpenTofu (see [ADR-002](ADR-002-opentofu-terragrunt.md)) state is currently stored in local files, one per infrastructure unit. As the homelab grows, local state creates risks: no locking, no shared access, and state files tied to a single machine. A remote S3-compatible backend solves all three.

[Garage](https://garagehq.deuxfleurs.fr/) is a self-hosted, lightweight S3-compatible object store designed for small clusters. It fits the homelab constraint of avoiding external dependencies for core infrastructure.

The Garage instance must be available before any OpenTofu unit can migrate its state to it, which creates a bootstrapping constraint: Garage itself cannot be managed by a unit that depends on it. Hosting Garage inside Kubernetes would introduce a circular dependency, as the Kubernetes cluster (see [ADR-001](ADR-001-kubernetes.md)) is itself provisioned by OpenTofu. It also ties core storage availability to the health of the cluster scheduler.

## Decision

I will run Garage as a Proxmox LXC container and configure it as the S3 backend for all OpenTofu state. State will migrate unit by unit from local files as the Garage LXC is provisioned and confirmed stable, rather than in a single cutover.

## Consequences

- State locking and remote storage are available for all units once Garage is live
- Garage on LXC is independent of Kubernetes, eliminating the circular dependency between cluster provisioning and state storage
- Incremental migration reduces risk: each unit can be moved and verified individually, with local state as a fallback until migration is complete
- The Garage LXC must be treated as a hard dependency and provisioned before other units migrate; its own state bootstrap requires care (local state or a separately maintained state file)
- One more LXC to operate, monitor, and back up
- Garage is less mature than MinIO or AWS S3; some S3 API edge cases may surface

Amendment (2026-08-22): migration completed uniformly — bootstrap units included. The `proxmox/garage-lxc` and `garage/tofu-state` units moved to the same backend they provision. This trades the bootstrap circularity concern above against single-backend simplicity, and is acceptable because recovery starts from a restored bucket rather than local files. The planned off-site backup of the bucket contents is not deployed yet; until it lands, recovery relies on the host-local `terraform.tfstate.d/` copies and RPO equals their age (migration runbook §7). Once the repo-managed backup deploys, restore-first becomes the primary recovery path per [ADR-015](ADR-015-disaster-recovery.md) and the bootstrap caveat fully retires.
