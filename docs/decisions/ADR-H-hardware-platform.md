# ADR-H: Home Server Hardware Platform (Proxmox + Talos Homelab Build)

## Status

Active

## Context

The previous server was a repurposed desktop running an Intel Core i7-3770 (2012, 4c/8t, DDR3, 8GB RAM) with a 120GB SATA SSD, running bare-metal Docker Compose (see [ADR-001](ADR-001-kubernetes.md)). It had three hard limits that made it unsuitable for a Kubernetes migration:

- 8GB RAM was a ceiling; not enough to run a 4-node Talos (see [ADR-001](ADR-001-kubernetes.md)) cluster alongside existing workloads
- No integrated GPU (iGPU) capable of hardware transcoding at modern codecs (High Efficiency Video Coding (HEVC), AV1)
- Dead platform with no upgrade path

The old machine was disk-imaged into a Proxmox (see [ADR-000](ADR-000-project-goals.md)) VM to run in parallel during migration, avoiding service interruption.

Design goals, in priority order:

1. Small form factor (desk, not rack)
2. Low noise (home environment)
3. Low power (always-on; electricity cost compounds over years)
4. Cost-effective (justified spend, no over-speccing)

## Decision

I built a new server around the following components:

| Component      | Spec                                                                                                                    |
| -------------- | ----------------------------------------------------------------------------------------------------------------------- |
| CPU            | AMD Ryzen 5 8600G (6c/12t, 65W TDP, Radeon 760M iGPU, AM5)                                                              |
| Motherboard    | MSI MAG B650M Mortar WiFi (mATX, B650, 6× SATA, 2× M.2, 2.5GbE, Bluetooth)                                              |
| RAM            | Crucial Pro 2×16GB DDR5 6000MHz CL36 (AMD EXPO)                                                                         |
| Boot/k8s SSD   | Samsung 990 PRO 2TB NVMe PCIe 4.0                                                                                       |
| PSU            | Corsair RM750e 750W (fully modular, 0 RPM mode, Cybenetics Gold)                                                        |
| Case           | Sagittarius dual-chamber NAS chassis (mATX, 8 HDD bays, 4× 120mm PWM fans)                                              |
| HDDs           | 2× WD Red Plus 4TB (Tier 1) + 4× mixed HDDs (Tier 2), reused                                                            |
| OOB management | [Sipeed NanoKVM Lite](https://github.com/sipeed/NanoKVM) (HDMI capture, USB HID, virtual USB storage, 100Mbps Ethernet) |
| Hypervisor     | [Proxmox VE](https://www.proxmox.com/en/proxmox-virtual-environment)                                                    |

Key rationale:

**Ryzen 5 8600G.** The Radeon 760M iGPU handles hardware transcoding (H.264, HEVC, AV1) for Jellyfin (see [ADR-007](ADR-007-longhorn.md)) and GPU-accelerated ML inference for Immich (face detection, CLIP embeddings), offloading both from the CPU cores. At 65W Thermal Design Power (TDP) and typical 2-10% utilisation, actual power draw is well under the rated ceiling. AM5 has a confirmed roadmap through at least 2027, giving a CPU upgrade path that the old DDR3 platform couldn't offer.

**Sagittarius dual-chamber case.** The only desk-friendly mATX enclosure with 8 HDD bays and a full-height PCIe slot. The dual-chamber design isolates drive vibration from compute components. 4× 120mm PWM fans run near-silent at low load.

**DDR5 6000MHz with EXPO.** Dual-channel at this speed provides approximately 60-80 GB/s of bandwidth, which is what makes 7-8B Large Language Model (LLM) inference at Q4 quantisation viable at 4-8 tokens/second for async automation workflows. EXPO must be enabled in BIOS; the JEDEC default (4800MHz) is a meaningful step down. For all other workloads, the speed difference is imperceptible.

**750W PSU.** Current draw is well under 300W. The headroom accommodates a future RTX 3060 12GB (~170W TDP) without replacing the PSU. 0 RPM mode below thermal threshold means the PSU runs silently at typical load.

**[NanoKVM Lite](https://github.com/sipeed/NanoKVM).** AM5 consumer boards have no Intelligent Platform Management Interface (IPMI) or Baseboard Management Controller (BMC). The NanoKVM fills that gap externally: full screen access from BIOS through the OS, remote keyboard/mouse, and virtual USB storage for ISO boot, all over its own 100Mbps Ethernet port independent of the host network stack. ATX power control (KVM-B PCB) is planned but not yet wired up.

## Consequences

**Positive:**

- The Radeon 760M handles Jellyfin transcoding and Immich ML without competing with Kubernetes workloads for CPU time.
- DDR5 6000 makes CPU-based LLM inference viable for automation workflows without a discrete GPU.
- All 6 reused drives fit in the Sagittarius case with 2 bays spare, on a desk, quietly.
- Clear upgrade path: drop in a faster AM5 CPU, or add an RTX 3060 12GB for interactive LLM inference. The PCIe slot and PSU headroom are both ready.
- The stack is fully IaC-reproducible.

**Negative / trade-offs:**

- Single physical host: hardware failure means a full outage. Mitigated by reproducibility, not redundancy.
- Single control plane node: the Kubernetes API is unavailable when the CP VM is down. Existing workloads continue via kubelet.
- iGPU VRAM is carved from the 32GB system RAM, not additive.
- NanoKVM Lite can't remotely power-cycle a hung host yet; physical access is still needed for hard resets until the ATX control board is wired.
- No offsite backup for Tier 1 storage until [Phase 15](../../README.md#phases) (documented known gap). btrfs (see [ADR-020](ADR-020-storage-tier-strategy.md)) RAID 1 covers single-drive failure only.
- All 6 SATA ports are occupied; additional spinning drives require a PCIe SATA expansion card or the second M.2 slot.
