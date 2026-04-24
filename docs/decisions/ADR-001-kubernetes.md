# ADR-001: Kubernetes as the Homelab Orchestration Platform

## Status

Active

## Context

The previous setup was [Docker Compose](https://docs.docker.com/compose/) on bare metal, managed by SSH-ing in and running `docker compose pull && docker compose up -d`. It worked. During this period, I also used [Watchtower](https://github.com/containrrr/watchtower) while it was actively maintained to automate container updates. When rebuilding on new hardware, the question was whether to continue with that approach or move to something more sophisticated.

Two goals from [ADR-000](ADR-000-project-goals.md) shaped the decision: 100% IaC reproducibility, and a live system as a portfolio artefact demonstrating production infrastructure skills. The background is 10+ years of AWS Cloud Infrastructure experience, with [Kubernetes](https://kubernetes.io/) being the leading orchestration platform in this domain. Deepening operational expertise in this area was a key focus.

The honest case against Kubernetes for a homelab is real: operational complexity is higher, the learning curve is steep and front-loaded, and single-node deployment defeats most of the HA argument. If the machine is unavailable, everything is unavailable regardless of what the scheduler thinks it can reschedule. Running [Immich](https://immich.app/) and [Home Assistant](https://www.home-assistant.io/) does not require [CiliumNetworkPolicies](https://docs.cilium.io/en/stable/network/kubernetes/policy/). These objections are noted and accepted.

## Decision

I will use Kubernetes as the primary orchestration platform, managed via ArgoCD (as decided in [ADR-003](ADR-003-argocd.md)) following a GitOps approach (as established in [ADR-000](ADR-000-project-goals.md)), running on [Talos Linux](https://www.talos.dev/).

For IaC reproducibility: Kubernetes forces everything into declarative manifests. There is no "log in and run a command" path for normal operations. Combined with ArgoCD, the git repository is the authoritative cluster state, continuously reconciled. Docker Compose can be done with discipline; Kubernetes makes the undisciplined path structurally harder.

For the portfolio: Kubernetes is the platform where production infrastructure runs. The ecosystem around it (ArgoCD, cert-manager, [Longhorn](https://longhorn.io/), Cilium, [CloudNativePG](https://cloudnative-pg.io/), [Velero](https://velero.io/), [Kyverno](https://kyverno.io/), [Trivy](https://trivy.dev/), Renovate) is a full production-grade operational stack, all open source, all designed to compose together. That stack produces capabilities a Compose setup cannot replicate without significant custom work: continuous GitOps reconciliation with drift detection, replicated persistent storage via [Container Storage Interface (CSI)](https://github.com/container-storage-interface/spec/blob/master/spec.md), admission control and policy enforcement, cluster-level backup and restore including [PersistentVolumeClaim (PVC)](https://kubernetes.io/docs/concepts/storage/persistent-volumes/) data.

Services that don't fit Kubernetes naturally (Home Assistant, [AdGuard](https://adguard.com/en/adguard-home/overview.html), Garage (see [ADR-010](ADR-010-garage.md)), Network File System (NFS)) run as Proxmox LXCs or VMs. Kubernetes is used where appropriate, not everywhere.

## Alternatives Considered

**Docker Compose**: Remains the right tool for the migration staging environment. For the long-term goals, it has no GitOps reconciliation engine, no CSI-backed persistent storage, no admission control, and no cluster-level backup with PVC data. These are architectural gaps, not discipline gaps. [Nginx Proxy Manager](https://nginxproxymanager.com/) covers automatic TLS for the reverse-proxy use case, and Renovate supports Compose files natively, but neither addresses what's actually missing.

**[Docker Swarm](https://docs.docker.com/engine/swarm/)**: Effectively in maintenance mode. No meaningful investment from [Docker Inc](https://www.docker.com/company/) for years. Offers a middle ground between Compose and Kubernetes that satisfies neither use case well, and it's a dead end for a production skills portfolio.

**[HashiCorp Nomad](https://www.nomadproject.io/)**: Evaluated seriously. The [Consul](https://www.consul.io/) + [Vault](https://www.vaultproject.io/) + Nomad stack is coherent, the mental model is simpler, and operational overhead is lower. Rejected because the ecosystem is thinner: cert-manager, Longhorn, Cilium, and ArgoCD all have Kubernetes as a hard dependency, and the Nomad equivalents are less mature or absent. Nomad experience also transfers less directly to professional contexts, which conflicts with the portfolio goal. For a homelab with no portfolio intent, it would be a compelling choice.

**Lightweight distributions ([k3s](https://k3s.io/), [k0s](https://k0sproject.io/), [MicroK8s](https://microk8s.io/))**: k3s in particular has a large homelab community and would have been faster to get running. Passed over in favour of Talos Linux. k3s makes pragmatic trade-offs (e.g. bundled components, simplified installation, relaxed security posture) that are reasonable for getting started but undermine the "real system" goal. If the point is to demonstrate how production Kubernetes works, running production-grade tooling from the start is more valuable than saving setup time.

**Talos Linux**: Chosen over standard Kubernetes distributions and k3s. Talos is an immutable operating system built specifically for Kubernetes. The OS has no SSH, no shell, and no package manager. Configuration is declarative and API-driven. This aligns perfectly with the IaC philosophy: the entire system stack, from the OS layer up, is defined in git and applied via automation. There's no manual system administration path to drift from the declared state.

The security posture is a direct consequence of the design. The attack surface is minimal because there's no general-purpose OS underneath. No SSH means no credentials to leak or rotate. No shell means no runtime exec attacks. The immutable root filesystem means malware can't persist across reboots. For a homelab exposed to the internet via Cloudflare Tunnel, this defense-in-depth model reduces the blast radius of any container escape or cluster compromise.

Talos also forces the same operational discipline I want for applications: everything is a manifest, everything is versioned, everything is reproducible. Running Talos makes the infrastructure layer as code-first as the workloads.

## Consequences

**Positive:**

- Git is the enforced source of truth; no manual `kubectl apply` in normal operation
- Full operational stack in place: ArgoCD, cert-manager, Longhorn, Cilium, Velero, Kyverno, Trivy
- Talos immutability enforces IaC discipline at the OS layer, not just the application layer
- Minimal attack surface from Talos design reduces risk of persistent compromise
- Portfolio demonstrates hands-on Kubernetes experience on the platform production infrastructure actually runs on
- IaC reproducibility is enforced structurally by the GitOps model and Talos immutability, not by individual discipline

**Negative / accepted costs:**

- Higher time investment upfront; weeks of infrastructure work before a single application is deployed
- More complex failure modes; debugging requires understanding Custom Resource Definition ([CRD](https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/))s, controllers, CSI drivers, Container Network Interface ([CNI](https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/network-plugins/)) plugins
- Talos adds another abstraction layer with its own API and troubleshooting patterns
- Single-host HA limitations: hardware failure takes everything down regardless of Kubernetes
- Ongoing operational overhead as a permanent tax on running the system

The learning curve and the failure modes are partly the point. A setup that never produces interesting problems teaches nothing.
