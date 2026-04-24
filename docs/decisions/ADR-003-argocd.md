# ADR-003: ArgoCD as the GitOps Controller for Kubernetes

## Status

Active

## Context

With Kubernetes adopted ([ADR-001](ADR-001-kubernetes.md)), the next question is how to manage cluster state. Running `kubectl apply` manually after each change doesn't solve the drift problem: state diverges from the repository, manual steps are required to converge, and nothing detects the gap.

GitOps inverts this. A controller runs inside the cluster, watches a git repository, and continuously reconciles actual state to declared state. The repository becomes the source of truth by enforcement, not convention.

The two options evaluated were [ArgoCD](https://argo-cd.readthedocs.io/en/stable/) and [FluxCD](https://fluxcd.io).

**[FluxCD](https://fluxcd.io)** was ruled out for two reasons. First, [Weaveworks](https://weaveworks.org/), its primary institutional backer and the employer of most core maintainers, shut down in February 2024. The project continues under CNCF governance with a volunteer team, but maintenance velocity slowed after the shutdown and the project carries elevated continuity risk over a 3-5 year horizon. Second, FluxCD has no web UI. Its operational model is entirely CLI-driven, which limits demonstrability and increases cognitive load during incidents.

**[ArgoCD](https://argo-cd.readthedocs.io/en/stable/)** has 52% production adoption in the [CNCF Annual Survey (January 2026, 628 respondents)](https://www.cncf.io/wp-content/uploads/2026/01/CNCF_Annual_Survey_Report_final.pdf). Institutional backing is diversified across [Intuit](https://www.intuit.com) (origin), [Red Hat](https://www.redhat.com) (ships ArgoCD as [OpenShift GitOps](https://docs.openshift.com/gitops/latest/understanding-openshift-gitops/about-redhat-openshift-gitops.html)), and [Akuity](https://akuity.io) (commercial services, founded by the ArgoCD creators). Three organizations with commercial stakes in its continued health is a different risk profile than a community-only maintainer team.

ArgoCD ships a full web UI with real-time Application state, live diffs between git and cluster, sync triggers, and rollback to any prior git commit. During an incident, this replaces a sequence of `kubectl get` and `kubectl describe` calls across namespaces with a single view. For a portfolio environment, it makes the GitOps model directly demonstrable without a lengthy tooling explanation.

The Argo ecosystem ([Rollouts](https://argoproj.github.io/rollouts/) for canary/blue-green deployments, [Workflows](https://argoproj.github.io/workflows/) for in-cluster pipelines, [Events](https://argoproj.github.io/events/) for webhook-driven automation) is composable if needed later, without additional tooling decisions. The [ApplicationSet controller](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/) supports an [App of Apps](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/) pattern where adding a new service means adding a directory; the ApplicationSet picks it up automatically on the next sync.

**Bootstrap**: GitOps has a chicken-and-egg problem. ArgoCD must be installed before it can manage anything. The solution is a one-time OpenTofu (see [ADR-002](ADR-002-opentofu-terragrunt.md)) `null_resource` running `helm upgrade --install argocd`. Once running, ArgoCD self-manages via an Application pointing at `kubernetes/infrastructure/argocd/`. Future config changes go through the GitOps loop like any other Application. A root [App of Apps](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/) Application discovers all child Applications by directory structure. If ArgoCD enters a crash loop, `docs/runbooks/argocd-breakglass.md` covers recovery.

## Decision

I will use [ArgoCD](https://argo-cd.readthedocs.io/en/stable/) as the GitOps controller for all Kubernetes workloads. ArgoCD is bootstrapped once via Helm (see [ADR-000](ADR-000-project-goals.md)) through OpenTofu, then made self-managing via an Application pointing at its own config in git. A root [App of Apps](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/) Application manages all child Applications by directory discovery.

## Consequences

**Positive:**

- All workloads are ArgoCD-managed; `kubectl apply` is not used in normal operation
- Drift is detected and corrected automatically on every reconciliation cycle, not only on git push
- Adding a new service is a git commit, not a Helm command
- The web UI provides operational visibility from day one and is demonstrable to anyone reviewing the repo
- Renovate (see [ADR-004](ADR-004-renovate.md)) handles ArgoCD version bumps the same as any other dependency
- The Argo ecosystem ([Rollouts](https://argoproj.github.io/rollouts/), [Workflows](https://argoproj.github.io/workflows/), [Events](https://argoproj.github.io/events/)) is available without additional tooling decisions if advanced deployment strategies are needed later

**Negative:**

- ArgoCD adds operational overhead: [Redis](https://redis.io/), CRDs, its own Application state database
- Self-management creates a specific failure mode: a crash-looping ArgoCD cannot fix itself; the break-glass runbook is a required deliverable at [Phase 1](../../README.md#phases), before the dependency exists
- The web UI is an attack surface; it's not exposed via the [Gateway API](https://gateway-api.sigs.k8s.io) until Authentik (see [ADR-008](ADR-008-authentik.md)) OIDC is live ([Phase 5/6](../../README.md#phases)), so access is via `kubectl port-forward` only in the interim, with the admin password SOPS (see [ADR-009](ADR-009-sops.md))-encrypted immediately after bootstrap
- The bootstrap step is imperative and can't be GitOps-ified; this is accepted as inherent to any GitOps bootstrap
