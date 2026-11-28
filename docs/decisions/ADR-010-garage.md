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

Amendment (2026-11-28): the Garage provider source is now `geripgeri/garage`, pinned to `1.2.3`, instead of `schwitzd/garage` `1.2.2`. Garage itself is pinned to 2.5.0. The upstream provider cannot decode the `resyncQueueLen` field that Garage 2.5.0 adds to `GetClusterStatus`, and its older admin SDK cannot decode the `corsRules`/`lifecycleRules` fields added in Garage 2.2, so every plan fails before resource evaluation. The fixes are in [upstream PR #7](https://github.com/Schwitzd/terraform-provider-garage/pull/7), still open, so the fork is published as a registry release. Trade-off: a single-maintainer fork needs tracking until upstream merges; an exact version pin plus committed hashes limits silent drift. Changing the source changes the provider address stored in state, so both garage units need a one-time `tofu state replace-provider` on the host before the first plan or apply. Do not apply the garage stack before that migration: OpenTofu would plan to destroy and recreate the buckets and keys. The exact commands are in the [Garage runbook](../runbooks/garage-lxc-setup.md). Rollback: restore the previous catalog source and lock files, run the reverse `replace-provider`, and keep the pre-migration state backup until a clean plan confirms the rollback.
