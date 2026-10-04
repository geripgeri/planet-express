# ADR-003: ArgoCD as the GitOps Controller for Kubernetes

## Status

Active

## Context

ArgoCD manages cluster state; the platform decision is in [ADR-001](ADR-001-kubernetes.md). Running `kubectl apply` manually after each change does not solve drift: state diverges from the repository, converging needs manual steps, and nothing detects the gap. GitOps inverts this. A controller inside the cluster watches a git repository and reconciles actual state to declared state, so git becomes the source of truth by enforcement, not convention.

The two options evaluated were [ArgoCD](https://argo-cd.readthedocs.io/en/stable/) and [FluxCD](https://fluxcd.io).

**[FluxCD](https://fluxcd.io)** was ruled out for two reasons. First, [Weaveworks](https://weaveworks.org/), its primary institutional backer and the employer of most core maintainers, shut down in February 2024. The project continues under CNCF governance with a volunteer team, but maintenance velocity slowed and continuity risk is elevated over a 3-5 year horizon. Second, FluxCD has no web UI: its operational model is entirely CLI-driven, which limits demonstrability and raises cognitive load during incidents.

**[ArgoCD](https://argo-cd.readthedocs.io/en/stable/)** has 52% production adoption in the [CNCF Annual Survey (January 2026, 628 respondents)](https://www.cncf.io/wp-content/uploads/2026/01/CNCF_Annual_Survey_Report_final.pdf). Institutional backing is diversified across [Intuit](https://www.intuit.com) (origin), [Red Hat](https://www.redhat.com) (ships ArgoCD as [OpenShift GitOps](https://docs.openshift.com/gitops/latest/understanding-openshift-gitops/about-redhat-openshift-gitops.html)), and [Akuity](https://akuity.io) (commercial services, founded by the ArgoCD creators). Three organizations with commercial stakes in its continued health is a different risk profile than a community-only maintainer team. The web UI gives real-time Application state, live diffs between git and cluster, sync triggers, and rollback to any prior git commit, which replaces a sequence of `kubectl get` and `kubectl describe` calls across namespaces with a single view during an incident.

The wider Argo ecosystem ([Rollouts](https://argoproj.github.io/rollouts/) for canary/blue-green deployments, [Workflows](https://argoproj.github.io/workflows/) for in-cluster pipelines, [Events](https://argoproj.github.io/events/) for webhook-driven automation) is composable later without extra tooling decisions. The [ApplicationSet controller](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/) supports an [App of Apps](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/) pattern where adding a new service means adding a directory.

**Bootstrap**: GitOps has a chicken-and-egg problem, because ArgoCD must be installed before it can manage anything, so the chart install runs through OpenTofu (see [ADR-002](ADR-002-opentofu-terragrunt.md)) `helm_release` before ArgoCD self-manages the config-only directory `kubernetes/infrastructure/argocd/` through an App of Apps Application. If ArgoCD enters a crash loop, `docs/runbooks/argocd-breakglass.md` covers recovery.

## Decision

I will use [ArgoCD](https://argo-cd.readthedocs.io/en/stable/) as the GitOps controller for all Kubernetes workloads. An OpenTofu `helm_release` (see [ADR-002](ADR-002-opentofu-terragrunt.md)) installs ArgoCD and owns every chart-rendered resource. A self-management Application owns only the config-only directory `kubernetes/infrastructure/argocd/`. Merging to main is the approval gate for changes there. A root [App of Apps](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/) Application manages all child Applications by directory discovery.

## Consequences

**Positive:**

- All workloads are ArgoCD-managed; `kubectl apply` is not used in normal operation
- Drift is detected and corrected on every reconciliation cycle, not only on git push
- Adding a service is a git commit, not a Helm command
- The web UI gives operational visibility from day one and is demonstrable to anyone reviewing the repo
- Renovate (see [ADR-004](ADR-004-renovate.md)) handles ArgoCD version bumps like any other dependency
- The Argo ecosystem ([Rollouts](https://argoproj.github.io/rollouts/), [Workflows](https://argoproj.github.io/workflows/), [Events](https://argoproj.github.io/events/)) is available without extra tooling decisions if advanced deployment strategies are needed later

**Negative:**

- ArgoCD adds operational overhead: [Redis](https://redis.io/), CRDs, its own Application state database
- Self-management creates a failure mode: a crash-looping ArgoCD cannot fix itself, so the break-glass runbook is a required deliverable at [Phase 1](../../README.md#phases), before the dependency exists
- The web UI is an attack surface. It is not exposed via the [Gateway API](https://gateway-api.sigs.k8s.io) until Authentik (see [ADR-008](ADR-008-authentik.md)) OIDC is live ([Phase 5/6](../../README.md#phases)), so interim access is via `kubectl port-forward` only, with the admin password SOPS (see [ADR-009](ADR-009-sops.md))-encrypted immediately after bootstrap
- Resource ownership splits at the chart boundary: `helm_release` owns chart-rendered resources, the self-management Application owns only `kubernetes/infrastructure/argocd/`. A manifest on both sides causes sync fights, so that directory stays config-only
- The bootstrap step runs before the GitOps loop exists and cannot be GitOps-ified; this is accepted as inherent to any GitOps bootstrap
