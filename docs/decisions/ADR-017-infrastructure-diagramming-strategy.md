# ADR-017: Infrastructure Diagramming Strategy

## Status

Active

## Context

One of the two non-negotiable goals for this project (see [ADR-000](ADR-000-project-goals.md)) is live documentation that reflects the actual running state. For infrastructure, that means diagrams in `docs/diagrams/` must stay accurate as the stack evolves. Hand-maintained GUI diagrams fail this within weeks: the first time a new LXC is added or a Kubernetes component changes, the diagram is stale.

This is also a portfolio repo. Diagrams give a reader orientation before they read anything else. A missing or stale architecture diagram forces them to reconstruct topology from code, which they won't do.

The stack has three layers with different diagramming needs:

- **OpenTofu resources**: Terragrunt units, modules, and provider relationships. Structured data; auto-generation is feasible.
- **Kubernetes workloads**: services, deployments, volumes, and ingress routes per namespace. Also structured, but from a different source (git manifests or live cluster).
- **Full architecture**: Proxmox host, VMs, LXCs, Kubernetes cluster, storage tiers, network flow, external services. Cross-layer relationships (which LXC exports what, how config sync works, what serves as both state backend and backup target) are not encoded in any structured data source. This layer must be hand-maintained.

## Decision

I decided to use a three-tool strategy, one per layer, with CI automation where auto-generation is viable.

**Layer 1: OpenTofu resources → inframap**

[inframap](https://github.com/cycloidio/inframap) reads OpenTofu state and generates a provider-aware dependency graph in Graphviz DOT, rendered to SVG. It focuses on meaningful relationships rather than listing every resource.

```bash
tofu state pull | inframap generate --tfstate | dot -Tsvg > docs/diagrams/terraform.svg
```

For the [telmate/proxmox](https://github.com/Telmate/terraform-provider-proxmox) provider, this produces an accurate VM/LXC/network dependency graph. Runs in CI on any merge touching `infrastructure/`; state is pulled from Garage (see [ADR-010](ADR-010-garage.md)) S3 using pipeline credentials.

**Layer 2: Kubernetes workloads → KubeDiagrams**

[KubeDiagrams](https://github.com/philippemerle/KubeDiagrams) generates diagrams from YAML manifests in git, no live cluster access required in CI.

```bash
kube-diagrams kubernetes/infrastructure/ -o docs/diagrams/k8s-infrastructure.png
kube-diagrams kubernetes/apps/ -o docs/diagrams/k8s-apps.png
```

Running it manually against the live cluster serves as a drift detector. If the output diverges from the CI-generated diagram, something was applied outside ArgoCD (see [ADR-003](ADR-003-argocd.md)).

```bash
kubectl get all -o yaml -n monitoring | kube-diagrams -o /tmp/live-monitoring.png
```

Runs in CI on any merge touching `kubernetes/`.

**Layer 3: Full architecture → Mermaid in markdown**

`docs/diagrams/architecture.md` contains a hand-maintained [Mermaid](https://mermaid.js.org) diagram. Mermaid renders natively in Gitea, GitHub and Codeberg with no build step. Updated when the topology changes meaningfully (new LXC, new major service, changed network path). Updating it is part of the definition of done for topology changes.

**Supplementary: terraform-docs for module READMEs**

[terraform-docs](https://terraform-docs.io/) auto-generates inputs/outputs/providers tables into each module's `README.md`. Anyone browsing `infrastructure/catalogs/` on GitHub / Codeberg gets a readable interface description without opening HCL (see [ADR-002](ADR-002-opentofu-terragrunt.md)).

**CI workflow**

All auto-generated diagrams are committed back by the pipeline with `[skip ci]` to prevent a loop.

**Alternatives rejected**: Terravision has no mapping for the telmate/proxmox provider resources and fragility against newer OpenTofu state formats. [Blast Radius](https://github.com/28mm/blast-radius) has been unmaintained since 2020 and was broken on OpenTofu 1.x. A single tool for all layers doesn't exist: inframap can't read Kubernetes manifests, KubeDiagrams can't read OpenTofu state, and no tool can generate the full-architecture layer. All-hand-drawn diagrams fail on maintenance: they go stale after the first topology change.

## Consequences

- `docs/diagrams/` contains four artefacts: `terraform.svg`, `k8s-infrastructure.png`, `k8s-apps.png` (all auto-generated), and `architecture.md` (Mermaid, hand-maintained).
- Auto-generated diagrams update on every merge touching `infrastructure/` or `kubernetes/` with no manual step.
- Divergence between the live-cluster KubeDiagrams output and the CI output signals a GitOps violation.
- `architecture.md` renders natively in Gitea and Codeberg; it's the primary entry point for anyone reading the repo cold.
- Each module under `infrastructure/catalogs/` has an auto-generated `README.md` browsable on GitHub / Codeberg.
- The inframap step requires a self-hosted runner with Garage network access. Hosted-runner-only CI can't generate the OpenTofu diagram.
- Any topology change carries an obligation: if it affects the whole-system picture, `architecture.md` must be updated in the same commit.
