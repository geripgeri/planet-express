# ADR-H: Home Server Hardware Platform (Proxmox + Talos Homelab Build)

## Status

Active

## Context

The previous server was a repurposed desktop running an Intel Core i7-3770 (2012, 4c/8t, DDR3, 8GB RAM) with a 120GB SATA SSD, running bare-metal Docker Compose (see [ADR-001](ADR-001-kubernetes.md)). Three hard limits made it unsuitable for a Kubernetes migration:

- 8GB RAM was a ceiling, not enough for a 4-node Talos (see [ADR-001](ADR-001-kubernetes.md)) cluster alongside existing workloads
- No integrated GPU (iGPU) capable of hardware transcoding at modern codecs (High Efficiency Video Coding (HEVC), AV1)
- A dead platform with no upgrade path

The old machine was disk-imaged into a Proxmox (see [ADR-000](ADR-000-project-goals.md)) VM to run in parallel during migration, avoiding service interruption.

Design goals, in priority order:

1. Small form factor (desk, not rack)
2. Low noise (home environment)
3. Low power (always-on, and electricity cost compounds over years)
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

**Ryzen 5 8600G.** The Radeon 760M iGPU handles hardware transcoding (H.264, HEVC, AV1) for Jellyfin and GPU-accelerated ML inference for Immich (face detection, CLIP embeddings), offloading both from the CPU cores. At typical 2-10% utilisation, actual draw stays well under the 65W Thermal Design Power (TDP) rating. AM5 has a confirmed roadmap through at least 2027, giving a CPU upgrade path the old DDR3 platform could not.

**Sagittarius dual-chamber case.** The only desk-friendly mATX enclosure with 8 HDD bays and a full-height PCIe slot. The dual-chamber design isolates drive vibration from compute components, and 4× 120mm PWM fans run near-silent at low load.

**DDR5 6000MHz with EXPO.** Dual-channel at this speed provides roughly 60-80 GB/s of bandwidth, which is what makes 7-8B Large Language Model (LLM) inference at Q4 quantisation viable at 4-8 tokens/second for async automation workflows. EXPO must be enabled in BIOS; the JEDEC default (4800MHz) is a meaningful step down. Every other workload cannot tell the difference.

**750W PSU.** Current draw is well under 300W, and the headroom covers a future RTX 3060 12GB (~170W TDP) without a PSU replacement. 0 RPM mode below the thermal threshold means silence at typical load.

**[NanoKVM Lite](https://github.com/sipeed/NanoKVM).** AM5 consumer boards have no Intelligent Platform Management Interface (IPMI) or Baseboard Management Controller (BMC), so the NanoKVM fills that gap externally: full screen access from BIOS through the OS, remote keyboard/mouse, and virtual USB storage for ISO boot, over its own 100Mbps Ethernet port independent of the host network stack. ATX power control (KVM-B PCB) is planned but not yet wired.

## Consequences

**Positive:**

- The Radeon 760M handles Jellyfin transcoding and Immich ML without competing with Kubernetes workloads for CPU time
- DDR5 6000 makes CPU-based LLM inference viable for automation workflows without a discrete GPU
- All 6 reused drives fit in the Sagittarius case with 2 bays spare, on a desk, quietly
- Clear upgrade path: a faster AM5 CPU, or an RTX 3060 12GB for interactive LLM inference. The PCIe slot and PSU headroom are both ready
- The stack is fully IaC-reproducible

**Negative / trade-offs:**

- A single physical host, so hardware failure is a full outage. Mitigated by reproducibility, not redundancy
- A single control plane node, so the Kubernetes API is unavailable while the CP VM is down. Existing workloads continue via kubelet
- iGPU VRAM is carved from the 32GB system RAM, not additive
- The NanoKVM Lite cannot remotely power-cycle a hung host, so hard resets still need physical access until the ATX control board is wired
- No offsite backup for Tier 1 storage yet (a documented known gap). btrfs (see [ADR-020](ADR-020-storage-tier-strategy.md)) RAID 1 covers single-drive failure only
- All 6 SATA ports are occupied, so more spinning drives need a PCIe SATA expansion card or the second M.2 slot
