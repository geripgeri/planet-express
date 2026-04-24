# ADR-000: Homelab Architecture Principles: IaC, GitOps, and Public Portfolio

## Status

Active

## Context

This is a single-node homelab running on personally owned hardware. The workloads are real and used daily: a photo library, document archive, media server, home automation, and various self-hosted tools. It's also a learning environment for [Kubernetes](https://kubernetes.io/) and modern infrastructure practices, and a public portfolio artifact.

These roles create competing pressures. Real workloads demand reliability; learning benefits from experimentation; a portfolio demands transparency. Without explicit principles, homelab projects tend toward undocumented snowflakes: they work until they don't, and rebuilding them requires archaeology. A demo environment where nothing breaks teaches you to build demo clusters, not to operate real systems.

Every architectural decision in this project is evaluated against the goals defined here.

## Decision

I commit to four principles, applied to every phase of the project.

**100% Infrastructure as Code (IaC), fully reproducible.** The entire stack, from [Proxmox](https://www.proxmox.com/en/proxmox-virtual-environment/overview) host configuration to Kubernetes workloads, is expressed as code. If the physical host were destroyed tonight, the git repository plus a blank machine plus the runbooks in `docs/runbooks/` should be sufficient to rebuild everything. The definition of done for any phase: someone could clone the repo onto a fresh machine, follow the runbooks, and reproduce the result exactly.

**Live documentation, written at decision time.** Architecture Decision Records (ADRs) are written when decisions are made. Runbooks are tested against reality. Known gaps are documented explicitly. The goal is documentation that reflects the actual running state, not aspirational fiction written after the fact. The messy parts (such as workarounds or first attempts that failed) are documented while they're still fresh.

**Tested where feasible, using two tiers.** Static tests (`tofu validate`, `tofu fmt`, [`yamllint`](https://yamllint.readthedocs.io/en/stable/), [`ansible-lint`](https://ansible-lint.readthedocs.io/en/latest/)) run on hosted runners with no infrastructure dependency. Integration tests ([Terratest](https://terratest.gruntwork.io/) Go tests) deploy catalog modules against the real Proxmox API, assert on the result, and tear them down. Integration tests are scoped to catalog modules because a broken `lxc` module would silently affect every Linux Container (LXC) in the stack. CI runs on [Gitea](https://about.gitea.com/) (primary) and [GitHub Actions](https://github.com/features/actions) (mirror). Both tiers are free given the public repository exemption for self-hosted runners on GitHub Actions, so the mirror doubles as a live demonstration of the full test suite.

**Public portfolio with selective publishing.** All catalog modules, units, stacks, Kubernetes manifests, Ansible roles, ADRs, runbooks, and diagrams are public. Private subtrees (firewall rules, internal network topology, apps not ready for the portfolio) are excluded via [`.gitattributes`](https://git-scm.com/docs/gitattributes) export-ignore rules using [`git-filter-repo`](https://github.com/newren/git-filter-repo). Writing decisions in public is a forcing function: explaining a trade-off clearly enough for someone else to evaluate it produces better decisions than private notes to myself.

The tooling stack implements these principles directly:

- **[OpenTofu](https://opentofu.org/) + [Terragrunt](https://terragrunt.gruntwork.io/)** manage all infrastructure as code using the catalog/stack/unit pattern. Catalog modules (`infrastructure/catalogs/`) are pure HCL with no live values, browsable via `terragrunt catalog` and scaffoldable into new units. Each unit has one state file. Stacks declare dependency order and wire outputs between units, rather than scattering `dependency` blocks across unit files.
- **[Ansible](https://www.ansible.com/)** handles Proxmox host bootstrapping below OpenTofu's reach: disabling enterprise repositories, configuring a custom Pulse Width Modulation (PWM) fan curve, deploying [Grafana Alloy](https://grafana.com/oss/alloy/) for host-level metrics and logs.
- **[ArgoCD](https://argo-cd.readthedocs.io/en/stable/)** manages all Kubernetes workloads via [GitOps](https://opengitops.dev/). No manual `kubectl apply` in normal operation. [Helm](https://helm.sh/) bootstraps ArgoCD and [Cilium](https://cilium.io/) as one-time operations via OpenTofu `null_resource` before the GitOps loop can start.
- **[SOPS](https://github.com/getsops/sops) + [age](https://age-encryption.org/)** encrypts all secrets at rest. Encrypted secrets are committed to git. A clone plus the age private key is sufficient to deploy.
- **[Garage S3](https://garagehq.deuxfleurs.fr/)** is the target for remote OpenTofu state. State migrates unit by unit from local files as the Garage LXC is provisioned.

## Consequences

- Every phase has a definition of done tied to the IaC reproducibility goal.
- The IaC discipline creates real friction: provisioning through OpenTofu is slower than clicking through the Proxmox UI. This is intentional.
- Known gaps are documented rather than omitted. Local state files under `.terraform.tfstate.d/` are a temporary gap during the Garage S3 migration. Offsite backup for Tier 1 data is a deferred known risk.
- Integration tests require a self-hosted runner with network access to Proxmox and the cluster. One runner is registered to Gitea, one to the GitHub mirror. Both are free under GitHub's public repository exemption.
- Real consequences, such as [cert-manager](https://cert-manager.io/) failures or a [Renovate](https://docs.renovatebot.com/) pull request (PR) breaking workloads, force a genuine understanding of the system. This is the point.
