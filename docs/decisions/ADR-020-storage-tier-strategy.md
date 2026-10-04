# ADR-020: Storage Tier Strategy with btrfs RAID 1, btrfs + mergerfs, NFS LXC

## Status

Active

## Context

The homelab stores two fundamentally different categories of data. Irreplaceable data (many years of family photos and personal documents) cannot be reconstructed if lost, and silent bitrot is an unacceptable failure mode. Recreatable data (VM ISOs, VM backups, media files) can be re-downloaded if a drive fails.

The hardware is heterogeneous by necessity: two matched WD Red Plus 4TB NAS drives and four mixed spinning HDDs of varying sizes and ages, all carried over from the previous setup. Any architecture requiring uniform drive sizes would need new hardware purchases.

The existing Tier 0 storage (Samsung 990 PRO NVMe via Longhorn (see [ADR-007](ADR-007-longhorn.md))) handles Kubernetes persistent volumes but not large unstructured shared data: Longhorn volumes are block devices and do not support simultaneous multi-consumer access, while the photo and media libraries need a shared filesystem reachable from both inside and outside the cluster.

The central challenge across all tiers is silent bitrot. Spinning drives that sit mostly idle can return corrupted data without surfacing a read error, and traditional RAID 1 ([mdadm](https://raid.wiki.kernel.org/index.php/A_guide_to_mdadm) + ext4) only detects disagreements between mirrors if both copies are read and compared simultaneously, which mdadm does not do during normal operation. [btrfs](https://btrfs.readthedocs.io) checksums every block on write and verifies on every read, and a weekly `btrfs scrub` proactively finds and repairs corruption from the healthy copy before a corrupted file is accessed by an application.

## Decision

I will use three storage tiers:

**Tier 1 (irreplaceable data):** Two WD Red Plus 4TB drives formatted as a native btrfs RAID 1 filesystem, no mdadm or LVM. Data and metadata both use the `raid1` profile. A weekly `btrfs scrub` runs on the pool, and weekly incremental block-level deduplication runs via [duperemove](https://github.com/markfasheh/duperemove) after the scrub.

**Tier 2 (recreatable data):** Four mixed HDDs, each formatted individually as btrfs with the `single` profile. The four drives are pooled via [mergerfs](https://github.com/trapexit/mergerfs) JBOD (Just a Bunch Of Disks) at `/mnt/bulk` using the `mfs` (most free space) create policy with `minfreespace=50G`. A weekly btrfs scrub runs on each drive independently.

**Storage gateway:** Both tiers are mounted inside a dedicated Debian NFS LXC, which exports `/mnt/tier1` and `/mnt/bulk` via NFS. Kubernetes consumes these exports through the NFS CSI driver (see [ADR-007](ADR-007-longhorn.md)) with two StorageClasses (`nfs-tier1`, `nfs-tier2`), both with `reclaimPolicy: Retain`. Mounts and exports are managed declaratively through fstab and Ansible (see [ADR-016](ADR-016-ansible-for-proxmox-host-configuration.md)).

Key alternatives rejected:

- **mdadm RAID 1 + ext4** (current Tier 1 state): no per-block checksums, so a bit flip goes undetected unless both copies are read simultaneously. Not sufficient for a photo archive
- **btrfs on top of mdadm RAID 1**: btrfs RAID 1 already provides mirroring with checksumming, so two independent RAID layers add complexity with no capability
- **btrfs RAID 5/6**: a write-hole bug present since 2012 means a crash during a partial-stripe write can produce silently incorrect parity. The btrfs maintainers advise against production use
- **mdadm RAID 5/6 under btrfs**: wastes capacity on heterogeneous drives (usable space is `min_size × (n-1)`) for recreatable data whose recovery path is re-downloading anyway
- **[SnapRAID](https://www.snapraid.it)**: needs a dedicated parity drive at least as large as the largest data drive, which is 4TB (25%+ of the pool) to protect re-downloadable data
- **btrfs RAID 0 for Tier 2**: a single drive failure corrupts every file in the pool. mergerfs JBOD limits a failure to the files on that drive; all others remain intact.
- **[ZFS](https://openzfs.org)**: comparable checksumming and scrub, but Common Development and Distribution License (CDDL) licensing creates ongoing Linux kernel integration friction. btrfs gets the same properties in the mainline kernel
- **[Ceph](https://ceph.io) / [GlusterFS](https://www.gluster.org)**: built for multi-node distributed storage. On one physical host, replication sits within a single machine and gives no real hardware redundancy while consuming significant RAM and CPU
- **iSCSI instead of NFS**: block-level, so it cannot be mounted read-write by multiple consumers at once. NFS is the correct protocol for ReadWriteMany access semantics
- **Managing storage from the Proxmox host directly**: keeps storage configuration as a manual host-level concern instead of IaC-managed, and blurs the hypervisor/service boundary
- **Passing block devices to Talos nodes**: Talos (see [ADR-001](ADR-001-kubernetes.md)) is an immutable OS with no package manager, so maintaining `btrfs-progs`, `mergerfs`, and `nfs-kernel-server` inside it would break on every upgrade

## Consequences

**Positive:**

- Bitrot detection is proactive. Weekly scrubs find and repair corruption before an application accesses a corrupt file, and `btrfs scrub status` output is the primary storage health signal. Alertmanager (see [ADR-011](ADR-011-observability.md)) alerts on scrub errors
- Tier 1 survives a single drive failure. btrfs RAID 1 keeps running in degraded mode from the surviving drive, and adding a replacement and rebalancing restores full redundancy online without data loss
- Adding a Tier 2 drive is a live operation: format to btrfs single, mount, add to the mergerfs source list, remount. No rebalancing or rebuild. Heterogeneous Tier 2 drive sizes each contribute their full formatted capacity to the mergerfs pool with no alignment waste
- The NFS LXC is stateless from a data perspective, because the data lives on the physical drives. Rebuilding it from its IaC configuration restores NFS access in minutes without touching the underlying data
- `reclaimPolicy: Retain` on both StorageClasses means a `kubectl delete pvc` does not silently delete the photo library or the media archive. Released PVs need explicit manual cleanup

**Negative:**

- Tier 2 does not survive a drive failure without data loss. Files on the failed drive are lost, files on all other drives are unaffected, and recovery is to replace the drive, format to btrfs single, and re-download
- The NFS LXC is a single point of failure for Tier 1 and Tier 2 access. If it is down, Immich and Jellyfin (see [ADR-007](ADR-007-longhorn.md)) are unavailable. Recovery is fast, but the dependency is real
- No offsite backup for Tier 1 data. btrfs RAID 1 covers single drive failure, not simultaneous failure of both drives, physical loss, or theft. That gap is an accepted known gap, and until an offsite backup exists both WD Red Plus drives failing together means permanent loss of the photo and document archive
