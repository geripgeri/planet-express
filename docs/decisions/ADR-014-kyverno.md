# ADR-014: Kyverno as the Kubernetes Policy Engine

## Status

Active

## Context

A Kubernetes cluster without admission control depends on the person applying manifests to get them right. Missing resource limits cause noisy neighbours that degrade other workloads on the node. `latest` image tags make deployments non-reproducible and drift invisible. Privileged containers expand a workload's blast radius in ways that are not obvious on review. All of this is preventable at the admission layer.

CI linting ([kubeconform](https://github.com/yannh/kubeconform), [kube-score](https://github.com/zegl/kube-score), [Polaris](https://polaris.docs.fairwinds.com) in Gitea Actions, see [ADR-004](ADR-004-renovate.md)) catches violations before they reach the cluster, but it is not a substitute for admission control. An emergency `kubectl apply`, a Helm upgrade with a values override, or an ArgoCD sync from a branch that has not run CI all bypass it. The admission webhook is the invariant: it fires regardless of how the resource reaches the API server. CI linting is defence in depth, not the primary enforcement layer.

Two alternatives were evaluated against Kyverno:

[OPA Gatekeeper](https://open-policy-agent.github.io/gatekeeper/) is the Cloud Native Computing Foundation (CNCF) graduated project that preceded Kyverno in wide adoption. Its policies are written in [Rego](https://www.openpolicyagent.org/docs/latest/policy-language/), a purpose-built declarative query language with non-obvious evaluation semantics, and its two-step template-then-constraint model needs careful ArgoCD sync-wave ordering. Gatekeeper is the right choice for organisations with dedicated security engineers owning complex policy logic at scale. For a solo operator the Rego learning curve means policies get written once, never updated, and treated as opaque config.

[Kyverno](https://kyverno.io) policies are YAML describing the desired shape of a Kubernetes resource. For someone already working in YAML manifests all day, the cognitive load delta is minimal. Its `ClusterPolicy` resources are single CRDs with no two-step model, which makes ArgoCD management straightforward. Kyverno supports both validating and mutating policies, so a missing resource limit can be injected automatically in development instead of only rejected. It reached CNCF graduated status in November 2023.

Any admission webhook is an availability risk. If Kyverno is unavailable while a pod is being scheduled, Kubernetes must either admit the workload anyway (`failOpen`) or reject it (`failClosed`). On a single-host homelab where Kyverno runs on the cluster it protects, `failClosed` risks a crash loop blocking system pod scheduling, which is worse than a brief enforcement gap. The `failurePolicy` is set to `Ignore` initially and gets reviewed once Kyverno's reliability on this cluster is established.

For a GitOps system meant to be reproduced from scratch and handed to ArgoCD (see [ADR-003](ADR-003-argocd.md)), policy-as-code is correct for the same reason Infrastructure as Code (IaC) is correct for infrastructure: the intention is codified and auditable, not tribal.

## Decision

I decided to use Kyverno as the Kubernetes admission policy engine, deployed and managed by ArgoCD from `kubernetes/infrastructure/kyverno/`.

The initial policy set covers the high-signal, low-controversy invariants:

- **Resource limits required** on all containers (CPU and memory)
- **No `latest` image tags**: every image reference must use a pinned tag, enforced alongside Renovate (see [ADR-004](ADR-004-renovate.md)), which manages pinned tag lifecycle through automated pull requests
- **Approved registries only**: images must come from Docker Hub (`docker.io`), GitHub Container Registry (GHCR, `ghcr.io`), Quay.io (`quay.io`), or `registry.k8s.io` (Kubernetes Special Interest Group (SIG) images such as the NFS Container Storage Interface (CSI) driver). The allowlist is the registry domain, not the Docker Hub "official images" namespace, so third-party namespaces on these registries (such as `longhornio/*` or `n8nio/*`) are permitted
- **No privileged containers**, with named exceptions for Longhorn (see [ADR-007](ADR-007-longhorn.md)), Cilium (see [ADR-005](ADR-005-cilium-gateway-api.md)), and the NFS Container Storage Interface (CSI) driver, each committed as a named `PolicyException` resource with a documented rationale. The NFS CSI driver images from `registry.k8s.io` must be pinned with explicit `tag` values in the Helm values, because the chart default (`latest`) violates the no-`latest` rule

Mutation is used in development environments to inject default resource limits and standard labels on resources that arrive without them, instead of rejecting them outright.

The rollout follows an audit-before-enforce sequence. All policies start in `Audit` mode: violations are recorded as `PolicyViolation` events, but non-compliant resources are still admitted. Once every existing violation is resolved, policies switch to `Enforce`. Nothing moves to Enforce until the violation count reaches zero.

## Consequences

- Once Enforce mode is active, non-compliant resources are rejected at the API server, so operators need to understand the policy set before applying new workloads
- Every legitimately privileged workload needs a named `PolicyException` committed to git, which keeps the exception surface area auditable rather than silent
- Kyverno (admission enforcement), Polaris (cluster-wide visibility), CI linting (pre-admission fast feedback), and Trivy Operator (CVE scanning, see [ADR-013](ADR-013-cilium-network-policy.md)) cover different failure modes at different points in the delivery pipeline
- The audit-to-enforce transition means the cluster runs partially unenforced until all existing violations are resolved. This is a known and accepted temporary state
- `failurePolicy: Ignore` means a Kyverno outage produces a brief enforcement gap instead of blocking admission, the safer trade-off for a single-host cluster
- This decision does not build Rego skills. If policy complexity grows past what Kyverno's YAML model handles cleanly, reassessing in favour of Gatekeeper stays an option
