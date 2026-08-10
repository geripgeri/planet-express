# Homelab Infrastructure

A production-grade Kubernetes homelab on a single bare-metal host. Every non-obvious choice has an [Architecture Decision Record](#architecture-decision-records) explaining what was evaluated, what lost, and why.

10+ years in Cloud Infrastructure and DevOps, primarily AWS. This is both a learning environment for Kubernetes and a portfolio artifact demonstrating infrastructure thinking. Real workloads, real failures, real documentation.

The public mirror excludes internal network topology (`infrastructure/units/private/mikrotik/`) and apps not ready for public review (`kubernetes/apps/private/`). [SOPS](https://github.com/getsops/sops)-encrypted secrets in public paths are safe, they are ciphertext. The public mirror lives on GitHub.

## AI-Assisted Development

This homelab is developed with AI coding agents ([opencode](https://opencode.ai), Claude) substantially involved: they propose code, configuration, ADRs, and documentation. I direct, review, and approve every change before it reaches `main`, the agents write under the constraints in [AGENTS.md](AGENTS.md), and nothing ships without my check. This is a live system running my real workloads; unvetted output would surface as outages.

I state this plainly because the repo doubles as a portfolio: honesty about the workflow is part of the skill set it demonstrates.

______________________________________________________________________

## Goals

[ADR-000](docs/decisions/ADR-000-project-goals.md) establishes two goals that drive every decision:

**100% IaC, fully reproducible.** `git clone` + a blank machine + the bootstrap steps = full rebuild.

**A live system with live documentation.** Workloads are genuinely used. Documentation reflects actual state. Known gaps are documented as gaps.

______________________________________________________________________

## Hardware

| Component    | Spec                                                                                                      |
| ------------ | --------------------------------------------------------------------------------------------------------- |
| CPU          | AMD Ryzen 5 8600G (6c/12t, 65W TDP, Radeon 760M iGPU)                                                     |
| RAM          | 2×16GB DDR5 6000MHz (~60–80 GB/s — enables CPU LLM inference)                                             |
| Boot/k8s SSD | Samsung 990 PRO 2TB NVMe PCIe 4.0                                                                         |
| Tier 1 HDDs  | 2× WD Red Plus 4TB (btrfs RAID 1 — critical data)                                                         |
| Tier 2 HDDs  | 4× mixed HDDs (btrfs single + mergerfs — recreatable data)                                                |
| Case         | Sagittarius dual-chamber NAS (mATX, 8 HDD bays)                                                           |
| PSU          | Corsair RM750e 750W (0 RPM mode, headroom for future GPU)                                                 |
| Out-of-band  | [Sipeed NanoKVM Lite](https://wiki.sipeed.com/hardware/en/kvm/NanoKVM/index.html) (HDMI capture, web KVM) |
| Hypervisor   | [Proxmox VE](https://www.proxmox.com/en/proxmox-virtual-environment/overview)                             |

Current utilisation: CPU 2–10%, significant RAM headroom, running a full 4-node Talos cluster and a migration VM simultaneously.

Full rationale: [ADR-H](docs/decisions/ADR-H-hardware-platform.md)

______________________________________________________________________

## Stack

| Layer                         | Technology                                                                                                                                                                                            | ADR                                                                         |
| ----------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| Hypervisor                    | [Proxmox VE](https://www.proxmox.com/en/proxmox-virtual-environment/overview)                                                                                                                         | [ADR-H](docs/decisions/ADR-H-hardware-platform.md)                          |
| k8s distro                    | [Talos Linux](https://www.talos.dev/)                                                                                                                                                                 | [ADR-001](docs/decisions/ADR-001-kubernetes.md)                             |
| IaC provisioning              | [OpenTofu](https://opentofu.org/) + [Terragrunt](https://terragrunt.gruntwork.io/)                                                                                                                    | [ADR-002](docs/decisions/ADR-002-opentofu-terragrunt.md)                    |
| GitOps                        | [ArgoCD](https://argo-cd.readthedocs.io/en/stable/)                                                                                                                                                   | [ADR-003](docs/decisions/ADR-003-argocd.md)                                 |
| CNI + Gateway                 | [Cilium](https://cilium.io/) ([Gateway API](https://gateway-api.sigs.k8s.io/)) + [cert-manager](https://cert-manager.io/)                                                                             | [ADR-005](docs/decisions/ADR-005-cilium-gateway-api.md)                     |
| k8s storage                   | [Longhorn](https://longhorn.io/) (2 StorageClasses)                                                                                                                                                   | [ADR-007](docs/decisions/ADR-007-longhorn.md)                               |
| File storage                  | btrfs RAID 1 + btrfs+[mergerfs](https://github.com/trapexit/mergerfs) via NFS LXC                                                                                                                     | [ADR-020](docs/decisions/ADR-020-storage-tier-strategy.md)                  |
| Database                      | [CloudNativePG (CNPG)](https://cloudnative-pg.io/)                                                                                                                                                    | [ADR-006](docs/decisions/ADR-006-cloudnativepg.md)                          |
| Identity                      | [Authentik](https://goauthentik.io/)                                                                                                                                                                  | [ADR-008](docs/decisions/ADR-008-authentik.md)                              |
| Secrets                       | [SOPS](https://getsops.io/) + [age](https://age-encryption.org/v1)                                                                                                                                    | [ADR-009](docs/decisions/ADR-009-sops.md)                                   |
| Object storage                | [Garage](https://garagehq.deuxfleurs.fr/) (S3-compatible)                                                                                                                                             | [ADR-010](docs/decisions/ADR-010-garage.md)                                 |
| Observability                 | [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack) + [Loki](https://grafana.com/oss/loki/) + [Tempo](https://grafana.com/oss/tempo/) | [ADR-011](docs/decisions/ADR-011-observability.md)                          |
| Alerting                      | [Alertmanager](https://prometheus.io/docs/alerting/latest/alertmanager/) → [signal-cli](https://github.com/AsamK/signal-cli) → [Signal](https://signal.org/)                                          | [ADR-012](docs/decisions/ADR-012-alerting.md)                               |
| Network policy + CVE scanning | [Cilium](https://cilium.io/) NetworkPolicy + [Trivy Operator](https://aquasecurity.github.io/trivy-operator/latest/)                                                                                  | [ADR-013](docs/decisions/ADR-013-cilium-network-policy.md)                  |
| Policy                        | [Kyverno](https://kyverno.io/)                                                                                                                                                                        | [ADR-014](docs/decisions/ADR-014-kyverno.md)                                |
| Backup                        | [Velero](https://velero.io/) + etcd snapshots + [Barman](https://pgbarman.org/)                                                                                                                       | [ADR-015](docs/decisions/ADR-015-disaster-recovery.md)                      |
| Host config                   | [Ansible](https://www.ansible.com/)                                                                                                                                                                   | [ADR-016](docs/decisions/ADR-016-ansible-for-proxmox-host-configuration.md) |
| Updates                       | [Renovate](https://docs.renovatebot.com/)                                                                                                                                                             | [ADR-004](docs/decisions/ADR-004-renovate.md)                               |
| DNS                           | Dual [AdGuard](https://adguard.com/en/adguard-home/overview.html) LXC + [adguardhome-sync](https://github.com/bakito/adguardhome-sync)                                                                | [ADR-019](docs/decisions/ADR-019-adguard-ha-setup.md)                       |
| Remote access                 | [Tailscale](https://tailscale.com/)                                                                                                                                                                   | [ADR-018](docs/decisions/ADR-018-tailscale.md)                              |

______________________________________________________________________

## Storage Architecture

Three independent tiers with different durability profiles:

```
Tier 0 — Boot + Kubernetes volumes
  Samsung 990 PRO NVMe
  └── Longhorn (3-replica default; 1-replica for Prometheus/Loki/ephemeral)

Tier 1 — Irreplaceable data (photos, documents)
  2× WD Red Plus 4TB
  └── btrfs RAID 1 (native — no mdadm)
      ├── Weekly scrub: bitrot self-healing
      ├── Weekly duperemove: block-level dedup
      └── NFS export → k8s nfs-tier1 StorageClass

Tier 2 — Recreatable data (media, ISOs, backups)
  4× mixed HDDs
  └── btrfs single per drive + mergerfs pool
      ├── Weekly scrub: bitrot detection
      └── NFS export → k8s nfs-tier2 StorageClass
```

Why btrfs RAID 5/6, SnapRAID, and btrfs-over-mdadm were all rejected: [ADR-020](docs/decisions/ADR-020-storage-tier-strategy.md)

______________________________________________________________________

## Repository Structure

```
.
├── infrastructure/               # OpenTofu + Terragrunt
│   ├── root.hcl                  # Shared backend config, provider versions, common inputs
│   ├── secrets.yaml              # SOPS-encrypted secrets
│   ├── catalogs/                 # Pure HCL modules — no live values, no secrets
│   │   ├── public/
│   │   │   ├── lxc/              # Proxmox LXC pattern
│   │   │   ├── proxmox-vm/       # Proxmox VM pattern
│   │   │   ├── talos/            # Talos cluster + node config templates
│   │   │   ├── k8s-app/          # Generic k8s app (HTTPRoute, CNPG, ServiceMonitor)
│   │   │   ├── adguard-config/   # AdGuard provider: rewrites, filter lists, clients
│   │   │   └── authentik-app/    # Authentik provider: app + provider + policy
│   │   └── private/              # export-ignore — reveals network topology
│   │       └── mikrotik/
│   ├── stacks/                   # Dependency-ordered unit groups
│   │   ├── public/
│   │   │   ├── proxmox/
│   │   │   ├── garage/           # Strict apply order: LXC → buckets → keys
│   │   │   └── argocd/
│   │   └── private/
│   │       └── mikrotik/
│   └── units/                    # Live instantiations (one state file each)
│       ├── public/
│       │   ├── proxmox/          # LXCs + VMs (adguard, garage, nfs, talos nodes)
│       │   ├── garage/           # buckets/, keys/
│       │   ├── talos/
│       │   ├── adguard/
│       │   ├── argocd/
│       │   └── authentik/
│       └── private/
│           └── mikrotik/
│
├── kubernetes/                   # ArgoCD-managed manifests
│   ├── infrastructure/           # Platform components (deployed before apps)
│   │   ├── argocd/
│   │   ├── cert-manager/
│   │   ├── cilium/
│   │   ├── longhorn/
│   │   ├── cnpg/
│   │   ├── authentik/
│   │   ├── nfs-csi/
│   │   ├── kyverno/
│   │   ├── velero/
│   │   ├── trivy/
│   │   └── renovate/
│   └── apps/
│       ├── observability/        # kube-prometheus-stack, Loki, Tempo, OTel, signal-cli
│       ├── n8n/
│       ├── ollama/
│       └── private/              # export-ignore
│
├── ansible/                      # Proxmox host IaC / bootstrapping
│   ├── playbooks/                # bootstrap.yaml (apply), verify.yaml (read-only CI checks)
│   └── roles/
│       ├── proxmox_base/         # Repos, packages, sysctl, SSH hardening
│       ├── fan_control/          # Custom PWM fan curve
│       ├── pve_exporter/         # Prometheus exporter for Proxmox metrics
│       └── custom_scripts/
│
├── docs/
│   ├── decisions/                # Architecture Decision Records
│   ├── runbooks/                 # cluster-rebuild, proxmox-rebuild, argocd-breakglass
│   └── diagrams/                 # Mermaid + auto-generated (inframap, KubeDiagrams)
│
├── scripts/
│   └── link_adr.py               # ADR cross-reference validator
├── tests/
│   └── test_link_adr.py
│
├── pyproject.toml
├── uv.lock
├── .sops.yaml
├── .gitattributes                # export-ignore rules (controls public mirror contents)
└── renovate.json5
```

**Terragrunt pattern:** Catalogs are pure HCL modules with no live values. Units are live instantiations, one state file each. Stacks are dependency-ordered groups wiring units together.

**Public vs private:** All catalog modules, public units/stacks, all Kubernetes manifests, all Ansible roles, all ADRs, runbooks, and diagrams are mirrored. Mikrotik config and `kubernetes/apps/private/` are not.

______________________________________________________________________

## Architecture Decision Records

| ADR                                                                         | Decision                                  |
| --------------------------------------------------------------------------- | ----------------------------------------- |
| [ADR-000](docs/decisions/ADR-000-project-goals.md)                          | Project goals and philosophy              |
| [ADR-001](docs/decisions/ADR-001-kubernetes.md)                             | Kubernetes as orchestration platform      |
| [ADR-002](docs/decisions/ADR-002-opentofu-terragrunt.md)                    | OpenTofu + Terragrunt                     |
| [ADR-003](docs/decisions/ADR-003-argocd.md)                                 | ArgoCD over FluxCD                        |
| [ADR-004](docs/decisions/ADR-004-renovate.md)                               | Renovate over Dependabot                  |
| [ADR-005](docs/decisions/ADR-005-cilium-gateway-api.md)                     | Cilium Gateway API + cert-manager         |
| [ADR-006](docs/decisions/ADR-006-cloudnativepg.md)                          | CloudNativePG                             |
| [ADR-007](docs/decisions/ADR-007-longhorn.md)                               | Longhorn with single-replica StorageClass |
| [ADR-008](docs/decisions/ADR-008-authentik.md)                              | Authentik: forward auth + OIDC hybrid     |
| [ADR-009](docs/decisions/ADR-009-sops.md)                                   | SOPS + age                                |
| [ADR-010](docs/decisions/ADR-010-garage.md)                                 | Garage for OpenTofu remote state          |
| [ADR-011](docs/decisions/ADR-011-observability.md)                          | Self-hosted observability stack           |
| [ADR-012](docs/decisions/ADR-012-alerting.md)                               | Signal for alerting                       |
| [ADR-013](docs/decisions/ADR-013-cilium-network-policy.md)                  | Cilium NetworkPolicy + Trivy Operator     |
| [ADR-014](docs/decisions/ADR-014-kyverno.md)                                | Kyverno over OPA/Gatekeeper               |
| [ADR-015](docs/decisions/ADR-015-disaster-recovery.md)                      | Velero backup strategy                    |
| [ADR-016](docs/decisions/ADR-016-ansible-for-proxmox-host-configuration.md) | Ansible for Proxmox host config           |
| [ADR-017](docs/decisions/ADR-017-infrastructure-diagramming-strategy.md)    | Infrastructure diagramming strategy       |
| [ADR-018](docs/decisions/ADR-018-tailscale.md)                              | Tailscale over Headscale+OCI              |
| [ADR-019](docs/decisions/ADR-019-adguard-ha-setup.md)                       | Dual AdGuard LXC + adguardhome-sync       |
| [ADR-020](docs/decisions/ADR-020-storage-tier-strategy.md)                  | Storage tier strategy                     |
| [ADR-H](docs/decisions/ADR-H-hardware-platform.md)                          | Hardware platform                         |

______________________________________________________________________

## Phases

| Phase | Name                     | Key Deliverables                                                                                                                                                                | ADRs                                                                                                                                                                                                            | Status          |
| ----- | ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------- |
| 0     | Hardware & Hypervisor    | Build server; install Proxmox VE; wire NanoKVM; enable EXPO in BIOS                                                                                                             | [ADR-H](docs/decisions/ADR-H-hardware-platform.md)                                                                                                                                                              | _derived_       |
| 0.5   | Host Configuration       | Ansible bootstrap: fan control, pve-exporter, SSH hardening, sysctl tuning                                                                                                      | [ADR-016](docs/decisions/ADR-016-ansible-for-proxmox-host-configuration.md)                                                                                                                                     | _derived_       |
| 0.9   | Core Infrastructure LXCs | Garage S3 LXC (state backend); dual AdGuard LXC + adguardhome-sync; NFS LXC + btrfs RAID 1 + mergerfs                                                                           | [ADR-010](docs/decisions/ADR-010-garage.md), [ADR-019](docs/decisions/ADR-019-adguard-ha-setup.md), [ADR-020](docs/decisions/ADR-020-storage-tier-strategy.md)                                                  | **ADR-defined** |
| 1     | Kubernetes Bootstrap     | Talos cluster provisioned via OpenTofu; Cilium CNI deployed; ArgoCD one-time Helm bootstrap; break-glass runbook written                                                        | [ADR-001](docs/decisions/ADR-001-kubernetes.md), [ADR-002](docs/decisions/ADR-002-opentofu-terragrunt.md), [ADR-003](docs/decisions/ADR-003-argocd.md), [ADR-005](docs/decisions/ADR-005-cilium-gateway-api.md) | **ADR-defined** |
| 2     | GitOps Foundation        | ArgoCD self-managing via App of Apps; age key bootstrapped as cluster Secret; Renovate nightly workflow live; SOPS integration verified                                         | [ADR-003](docs/decisions/ADR-003-argocd.md), [ADR-004](docs/decisions/ADR-004-renovate.md), [ADR-009](docs/decisions/ADR-009-sops.md)                                                                           | **ADR-defined** |
| 3     | Storage & Databases      | Longhorn deployed (two StorageClasses); CNPG operator; cert-manager + wildcard cert via DNS-01                                                                                  | [ADR-006](docs/decisions/ADR-006-cloudnativepg.md), [ADR-007](docs/decisions/ADR-007-longhorn.md), [ADR-005](docs/decisions/ADR-005-cilium-gateway-api.md)                                                      | _derived_       |
| 3.5   | Gateway Verification     | Verify Cilium `ExtensionRef` forward auth syntax against deployed Cilium version; do not copy from pre-1.14 sources                                                             | [ADR-005](docs/decisions/ADR-005-cilium-gateway-api.md)                                                                                                                                                         | **ADR-defined** |
| 4     | Workload Migration       | Migrate Immich, Paperless-ngx, n8n, Jellyfin from Docker Compose to Kubernetes; each with dedicated CNPG cluster + Barman                                                       | [ADR-001](docs/decisions/ADR-001-kubernetes.md), [ADR-006](docs/decisions/ADR-006-cloudnativepg.md), [ADR-007](docs/decisions/ADR-007-longhorn.md)                                                              | **ADR-defined** |
| 5     | Identity & SSO           | Authentik deployed on CNPG + Longhorn; OIDC configured for Grafana, ArgoCD, Proxmox; forward auth for remaining services; ArgoCD exposed via Gateway                            | [ADR-008](docs/decisions/ADR-008-authentik.md), [ADR-005](docs/decisions/ADR-005-cilium-gateway-api.md), [ADR-003](docs/decisions/ADR-003-argocd.md)                                                            | **ADR-defined** |
| 6     | Observability & Alerting | kube-prometheus-stack, Loki, Tempo, OTel Operator deployed; Alertmanager → signal-cli-rest-api; Signal phone registration (manual step)                                         | [ADR-011](docs/decisions/ADR-011-observability.md), [ADR-012](docs/decisions/ADR-012-alerting.md)                                                                                                               | **ADR-defined** |
| 7     | Diagramming & Docs       | inframap CI for OpenTofu diagrams; KubeDiagrams CI for K8s workloads; Mermaid architecture.md hand-maintained; terraform-docs on catalog modules                                | [ADR-017](docs/decisions/ADR-017-infrastructure-diagramming-strategy.md)                                                                                                                                        | **ADR-defined** |
| 8     | Security Hardening       | NetworkPolicy audit-and-tighten (cross-namespace paths: Prometheus, ArgoCD, Authentik, CNPG, Longhorn); Trivy Operator deployed; Kyverno in Audit mode; all violations resolved | [ADR-013](docs/decisions/ADR-013-cilium-network-policy.md), [ADR-014](docs/decisions/ADR-014-kyverno.md)                                                                                                        | **ADR-defined** |
| 9     | Disaster Recovery        | Velero daily backup + 7-day retention; `talosctl etcd snapshot` daily; Velero restore test on scratch cluster; RTO estimate updated                                             | [ADR-015](docs/decisions/ADR-015-disaster-recovery.md)                                                                                                                                                          | **ADR-defined** |
| 10    | Policy Enforcement       | Kyverno switched to Enforce mode; RBAC permissions audit; secrets mount posture review                                                                                          | [ADR-014](docs/decisions/ADR-014-kyverno.md), [ADR-013](docs/decisions/ADR-013-cilium-network-policy.md)                                                                                                        | **ADR-defined** |
| 11    | Remote Access            | Tailscale subnet router deployed; ACL policy (owner vs. other users); MagicDNS split DNS with both AdGuard IPs                                                                  | [ADR-018](docs/decisions/ADR-018-tailscale.md), [ADR-019](docs/decisions/ADR-019-adguard-ha-setup.md)                                                                                                           | **ADR-defined** |
| 12    | Application Tracing      | OTel instrumentation for n8n and Immich; Tempo populated with application traces (OTel Operator already in place from [Phase 6](#phases))                                       | [ADR-011](docs/decisions/ADR-011-observability.md)                                                                                                                                                              | **ADR-defined** |
| 13    | Automation               | n8n + Ollama Renovate PR summarisation workflow; LLM inference validated at DDR5 6000MHz bandwidth                                                                              | [ADR-004](docs/decisions/ADR-004-renovate.md), [ADR-H](docs/decisions/ADR-H-hardware-platform.md)                                                                                                               | **ADR-defined** |
| 14    | Kyverno Policy Expansion | Add policies beyond initial set: RBAC constraints, namespace isolation rules, registry allowlist refinements                                                                    | [ADR-014](docs/decisions/ADR-014-kyverno.md)                                                                                                                                                                    | **ADR-defined** |
| 15    | Offsite Backup           | Offsite target for Tier 1 NFS data (Immich, Paperless-ngx); rclone/restic job; closes the sharpest known DR gap                                                                 | [ADR-015](docs/decisions/ADR-015-disaster-recovery.md), [ADR-020](docs/decisions/ADR-020-storage-tier-strategy.md), [ADR-H](docs/decisions/ADR-H-hardware-platform.md)                                          | **ADR-defined** |

______________________________________________________________________

## Runbooks

Planned, not yet written. Keyed to the phase deliverables in the table above:

- `docs/runbooks/cluster-rebuild.md` — Full cluster recovery from scratch
- `docs/runbooks/proxmox-rebuild.md` — Host-level steps Ansible cannot automate
- `docs/runbooks/argocd-breakglass.md` — Recovering ArgoCD when it cannot self-heal
- `docs/runbooks/tier1-migration.md` — mdadm+ext4 → btrfs RAID 1 (high risk, irreplaceable data)
- `docs/runbooks/tier2-migration.md` — LVM+ext4 → btrfs single + mergerfs (low risk, recreatable data)

______________________________________________________________________

## Getting Started

Install the full toolchain (uv, OpenTofu + Terragrunt via tfswitch/tgswitch, sops, age) by following the [install doc](docs/install.md).
