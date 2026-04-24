# ADR-020: Storage Tier Strategy — btrfs RAID 1, btrfs + mergerfs, NFS LXC

## Status

Active

## Context

The homelab stores two fundamentally different categories of data. Irreplaceable data (many years of family photos and personal documents) cannot be reconstructed if lost; silent bitrot is an unacceptable failure mode. Recreatable data (VM ISOs, VM backups, media files) can be re-downloaded if a drive fails.

The hardware is heterogeneous by necessity: two matched WD Red Plus 4TB NAS drives and four mixed spinning HDDs of varying sizes and ages, all carried over from the previous setup. Any architecture requiring uniform drive sizes would need new hardware purchases.

The existing Tier 0 storage (Samsung 990 PRO NVMe via Longhorn (see [ADR-007](ADR-007-longhorn.md))) handles Kubernetes persistent volumes but is not appropriate for large unstructured shared data. Longhorn volumes are block devices; they don't support simultaneous multi-consumer access. The photo and media libraries need a shared filesystem accessible from both inside and outside the cluster.

The central challenge across all tiers is silent bitrot. Spinning drives that sit mostly idle can return corrupted data without surfacing a read error. Traditional RAID 1 ([mdadm](https://raid.wiki.kernel.org/index.php/A_guide_to_mdadm) + ext4) detects disagreements between mirrors only if both copies are read and compared simultaneously, which mdadm does not do during normal operation. [btrfs](https://btrfs.readthedocs.io) checksums every block on write and verifies on every read; a weekly `btrfs scrub` proactively finds and repairs corruption from the healthy copy before a corrupted file is accessed by an application.

## Decision

I will use three storage tiers:

**Tier 1 (irreplaceable data):** Two WD Red Plus 4TB drives formatted as a native btrfs RAID 1 filesystem, no mdadm or LVM. Both data and metadata use the `raid1` profile. A weekly `btrfs scrub` runs on the pool; weekly incremental block-level deduplication runs via [duperemove](https://github.com/markfasheh/duperemove) after the scrub.

**Tier 2 (recreatable data):** Four mixed HDDs, each formatted individually as btrfs with the `single` profile. The four drives are pooled via [mergerfs](https://github.com/trapexit/mergerfs) JBOD (Just a Bunch Of Disks) at `/mnt/bulk` using the `mfs` (most free space) create policy with `minfreespace=50G`. A weekly btrfs scrub runs on each drive independently.

**Storage gateway:** Both tiers are mounted inside a dedicated Debian NFS LXC. The LXC exports `/mnt/tier1` and `/mnt/bulk` via NFS. Kubernetes consumes these exports via the NFS CSI driver (see [ADR-007](ADR-007-longhorn.md)) with two StorageClasses (`nfs-tier1`, `nfs-tier2`), both with `reclaimPolicy: Retain`. Mounts and exports are managed declaratively via fstab and Ansible (see [ADR-016](ADR-016-ansible-for-proxmox-host-configuration.md)).

Key alternatives rejected:

- **mdadm RAID 1 + ext4** (current Tier 1 state): No per-block checksums. A bit flip goes undetected unless both copies are read simultaneously, which mdadm does not do during normal operation. Not sufficient for a photo archive.
- **btrfs on top of mdadm RAID 1**: btrfs RAID 1 already provides mirroring with checksumming. Two independent RAID layers add operational complexity with no additional capability.
- **btrfs RAID 5/6**: A write-hole bug present since 2012 means a crash during a partial-stripe write can produce silently incorrect parity. The btrfs maintainers advise against production use.
- **mdadm RAID 5/6 under btrfs**: Wastes capacity on heterogeneous drives (usable space is `min_size × (n-1)`). Unjustified complexity for recreatable data when re-downloading is the recovery path anyway.
- **[SnapRAID](https://www.snapraid.it)**: Requires a dedicated parity drive at least as large as the largest data drive. That is 4TB of capacity (25%+ of the pool) to protect data that can be re-downloaded.
- **btrfs RAID 0 for Tier 2**: A single drive failure corrupts every file in the pool. mergerfs JBOD means a failure affects only files on that drive; all others remain intact.
- **[ZFS](https://openzfs.org)**: Comparable checksumming and scrub capabilities, but Common Development and Distribution License (CDDL) licensing creates ongoing Linux kernel integration friction. btrfs achieves the same properties and is part of the mainline kernel.
- **[Ceph](https://ceph.io) / [GlusterFS](https://www.gluster.org)**: Designed for multi-node distributed storage. On a single physical host, replication is within one machine and provides no real hardware redundancy while consuming significant RAM and CPU.
- **iSCSI instead of NFS**: Block-level; cannot be mounted read-write by multiple consumers simultaneously. NFS is the correct protocol for ReadWriteMany access semantics.
- **Managing storage from the Proxmox host directly**: Keeps storage configuration as a manual host-level concern rather than IaC-managed and blurs the hypervisor/service boundary.
- **Passing block devices to Talos nodes**: Talos (see [ADR-001](ADR-001-kubernetes.md)) is an immutable OS with no package manager. Installing and maintaining `btrfs-progs`, `mergerfs`, and `nfs-kernel-server` inside Talos would break on every upgrade.

## Consequences

**Positive:**

- Bitrot detection is proactive. Weekly scrubs find and repair corruption before an application accesses a corrupt file. `btrfs scrub status` output is the primary storage health signal; Alertmanager (see [ADR-011](ADR-011-observability.md)) alerts on scrub errors.
- Tier 1 survives a single drive failure. btrfs RAID 1 continues operating in degraded mode from the surviving drive; adding a replacement and rebalancing restores full redundancy online without data loss.
- Adding a Tier 2 drive is a live operation. Format to btrfs single, mount it, add to the mergerfs source list, remount. No rebalancing or rebuild required.
- Heterogeneous Tier 2 drive sizes contribute their full formatted capacity to the mergerfs pool with no alignment waste.
- The NFS LXC is stateless from a data perspective. The data lives on the physical drives. Rebuilding the LXC from its IaC configuration restores NFS access in minutes without touching the underlying data.
- `reclaimPolicy: Retain` on both StorageClasses means a `kubectl delete pvc` does not silently delete the photo library or the media archive. Released PVs require explicit manual cleanup.

**Negative:**

- Tier 2 does not survive a drive failure without data loss. Files on the failed drive are lost; files on all other drives are unaffected. Recovery is to replace the drive, format to btrfs single, and re-download the lost content.
- The NFS LXC is a single point of failure for Tier 1 and Tier 2 access. If the LXC is down, Immich and Jellyfin (see [ADR-007](ADR-007-longhorn.md)) are unavailable. Recovery is fast but the dependency is real.
- There is no offsite backup for Tier 1 data. btrfs RAID 1 protects against single drive failure, not simultaneous failure of both drives, physical loss, or theft. This gap is deferred to [Phase 15](../../README.md#phases). Until then, both WD Red Plus drives failing together means permanent loss of the photo and document archive.
