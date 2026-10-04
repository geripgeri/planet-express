# ADR-000: Homelab Architecture Principles: IaC, GitOps, and Public Portfolio

## Status

Active

## Context

Single-node homelab on personally owned hardware. The workloads are real and used daily: photo library, document archive, media server, home automation, and various self-hosted tools. It is also a learning environment for [Kubernetes](https://kubernetes.io/) and modern infrastructure practice, and a public portfolio artifact.

These roles pull in different directions. Real workloads demand reliability. Learning benefits from experimentation. A portfolio demands transparency. Without explicit principles, homelab projects become undocumented snowflakes: they work until they do not, and rebuilding needs archaeology. A demo environment where nothing breaks teaches you to build demo clusters, not to run real systems.

Every architectural decision here is evaluated against the goals below.

## Decision

I commit to four principles, applied to every phase.

**100% Infrastructure as Code (IaC), fully reproducible.** The whole stack, from [Proxmox](https://www.proxmox.com/en/proxmox-virtual-environment/overview) host configuration to Kubernetes workloads, is code. Destroy the physical host tonight and the git repository, a blank machine, and the runbooks in `docs/runbooks/` are enough to rebuild it. Definition of done for any phase: someone clones the repo onto a fresh machine, follows the runbooks, and reproduces the result exactly.

**Live documentation, written at decision time.** Architecture Decision Records (ADRs) are written when decisions are made. Runbooks are tested against reality. Known gaps are documented explicitly. Documentation reflects the running state, not aspirational fiction. Messy parts, such as workarounds and failed first attempts, are written down while fresh.

**Tested where feasible, in two tiers.** Static tests (`tofu validate`, `tofu fmt`, [`yamllint`](https://yamllint.readthedocs.io/en/stable/), [`ansible-lint`](https://ansible-lint.readthedocs.io/en/latest/)) run on hosted runners with no infrastructure dependency. Integration tests ([Terratest](https://terratest.gruntwork.io/) Go tests) deploy catalog modules against the real Proxmox API, assert on the result, and tear them down. Integration tests are scoped to catalog modules because a broken `lxc` module would silently affect every Linux Container (LXC) in the stack. CI runs on [Gitea](https://about.gitea.com/) (primary) and [GitHub Actions](https://github.com/features/actions) (mirror). Public mirrors live on GitHub and Codeberg (see [ADR-002](ADR-002-opentofu-terragrunt.md)). Both tiers are free under the public repository exemption for self-hosted runners on GitHub Actions, so the GitHub mirror doubles as a working demonstration of the full test suite.

**Public portfolio with selective publishing.** Catalog modules, units, stacks, Kubernetes manifests, Ansible roles, ADRs, runbooks, and diagrams are public. Private subtrees (firewall rules, internal network topology, apps not ready for the portfolio) are excluded through [`.gitattributes`](https://git-scm.com/docs/gitattributes) `export-ignore` rules using [`git-filter-repo`](https://github.com/newren/git-filter-repo). Writing decisions in public is a forcing function: explaining a trade-off well enough for someone else to evaluate it produces better decisions than private notes.

The tooling implements these principles directly:

- **[OpenTofu](https://opentofu.org/) + [Terragrunt](https://terragrunt.gruntwork.io/)** manage all infrastructure through the catalog/stack/unit pattern. Catalog modules (`infrastructure/catalogs/`) are pure HCL with no live values, browsable via `terragrunt catalog` and scaffoldable into new units. Each unit has one state file. Stacks declare dependency order and wire outputs between units instead of scattering `dependency` blocks across unit files.
- **[Ansible](https://www.ansible.com/)** handles Proxmox host bootstrapping below OpenTofu's reach: disabling enterprise repositories, configuring a custom Pulse Width Modulation (PWM) fan curve, deploying [Grafana Alloy](https://grafana.com/oss/alloy/) for host metrics and logs.
- **[ArgoCD](https://argo-cd.readthedocs.io/en/stable/)** manages all Kubernetes workloads via [GitOps](https://opengitops.dev/). No manual `kubectl apply` in normal operation. [Helm](https://helm.sh/) bootstraps ArgoCD and [Cilium](https://cilium.io/) before the GitOps loop can start, via OpenTofu `helm_release`.
- **[SOPS](https://github.com/getsops/sops) + [age](https://age-encryption.org/)** encrypt all secrets at rest. Encrypted secrets are committed to git. A clone plus the age private key is enough to deploy.
- **[Garage S3](https://garagehq.deuxfleurs.fr/)** is the target for remote OpenTofu state. State migrates unit by unit from local files as the Garage LXC is provisioned.

## Consequences

- Every phase has a definition of done tied to IaC reproducibility.
- IaC creates real friction: provisioning through OpenTofu is slower than clicking through the Proxmox UI. This is intentional.
- Known gaps are documented, not omitted. OpenTofu state now lives in the Garage S3 backend ([ADR-010](ADR-010-garage.md)); the local `terraform.tfstate.d/` copies stay as recovery source until off-site bucket backup deploys. Offsite backup for Tier 1 data is a deferred known risk.
- Integration tests need a self-hosted runner with network access to Proxmox and the cluster. One runner is registered to Gitea, one to the GitHub mirror. Both are free under GitHub's public repository exemption. Both public mirrors expose the code; Codeberg is a read-only push mirror without CI.
- Real consequences, such as [cert-manager](https://cert-manager.io/) failures or a [Renovate](https://docs.renovatebot.com/) pull request (PR) breaking workloads, force a genuine understanding of the system.
