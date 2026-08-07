# ADR-013: Cilium NetworkPolicy and Trivy Operator as the Cluster Security Layer

## Status

Active

## Context

A Kubernetes cluster running real workloads has a meaningful attack surface. Containers escape. Dependencies carry Common Vulnerabilities and Exposures (CVEs). Misconfigured service accounts grant more access than intended. Images pulled months ago have unpatched vulnerabilities in their base layers.

This ADR covers two of the three components in the cluster security layer: network traffic control (Cilium (see [ADR-005](ADR-005-cilium-gateway-api.md)) NetworkPolicy) and vulnerability scanning ([Trivy Operator](https://aquasecurity.github.io/trivy-operator/)). The third component, Kyverno, is addressed in [ADR-014](ADR-014-kyverno.md). Each layer catches a different class of problem independently, so a gap in one does not mean a gap everywhere.

The cluster runs Cilium as its CNI. Renovate (see [ADR-004](ADR-004-renovate.md)) handles proactive dependency bumps via PRs. The Prometheus/Grafana/Alertmanager stack is in place for metrics and alerting (see [ADR-011](ADR-011-observability.md)).

## Decision

**Cilium NetworkPolicy:** Every namespace gets a default-deny `CiliumNetworkPolicy` at creation time, not retroactively and not batched to a later security phase. Each workload's allow rules are deployed alongside its own manifests.

The default-deny template applied to every namespace:

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: default-deny
  namespace: <app-namespace>
spec:
  endpointSelector: {}
  ingress:
    - {}
  egress:
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: UDP
            - port: "53"
              protocol: TCP
```

All ingress is denied by default. Egress is denied except for DNS, which is a required carveout: without it, service name resolution fails silently in ways that are hard to diagnose. Both TCP and UDP firewall rules on port 53 must be allowed: CoreDNS answers large responses (SRV records, long TXT records) with the truncation (TC) bit set over UDP and expects the client to retry over TCP, which would be dropped if only UDP 53 is permitted. Explicit allow rules for real traffic paths are added as separate `CiliumNetworkPolicy` resources per workload.

`CiliumNetworkPolicy` CRDs are used instead of standard `networking.k8s.io/v1 NetworkPolicy` for three reasons. First, Layer 7 (L7) policy: standard NetworkPolicy operates at Layer 3/Layer 4 (L3/L4) only; Cilium's CRDs support path-level HTTP rules and DNS-name-based egress, which are the correct abstraction for fine-grained service-to-service controls. Second, [Hubble](https://docs.cilium.io/en/stable/overview/intro/) integration: when a policy denies a connection, Hubble shows the drop with full context (source endpoint, destination endpoint, matched rule), turning "something is broken" into "the Prometheus scraper is denied ingress because the allow rule references the wrong label selector." Third, no additional component: Cilium is already the CNI and the policy engine.

Batching default-deny to a later security phase has a specific failure mode: workloads deployed before it is applied may rely on implicit connectivity that was never documented. Applying retroactive restrictions to a running system means discovering undocumented connections by breaking them. Applying default-deny at namespace creation changes this: every workload must declare its connectivity requirements before it can talk to anything. [Phase 8](../../README.md#phases) remains a meaningful audit-and-tighten pass, covering cross-namespace paths for Prometheus scraping, ArgoCD (see [ADR-003](ADR-003-argocd.md)) sync, Authentik (see [ADR-008](ADR-008-authentik.md)) forward auth, CNPG (see [ADR-006](ADR-006-cloudnativepg.md)) replication, and Longhorn (see [ADR-007](ADR-007-longhorn.md)) CSI.

**Trivy Operator:** [Trivy Operator](https://aquasecurity.github.io/trivy-operator/) runs as a Kubernetes controller that continuously scans workload images and configurations, generating `VulnerabilityReport` and `ConfigAuditReport` CRDs per workload. A Prometheus `ServiceMonitor` scrapes Trivy's metrics endpoint. A Grafana dashboard surfaces CVE counts by severity and workload over time.

Renovate and Trivy are complementary, not redundant. Renovate is proactive and git-aware: it opens PRs to bump chart and image versions before a vulnerable image is deployed. It does not know what is running in the cluster. Trivy is reactive and in-cluster: it scans what is actually running against the Trivy vulnerability database, catching zero-days and newly published CVEs in already-deployed images, and detecting drift between git and the cluster (manual tag bumps, digest-pinned images, Helm values Renovate cannot track).

Trivy is chosen over [Grype](https://github.com/anchore/grype) and [Snyk](https://snyk.io) because it requires no external account or API key, the Trivy Operator is purpose-built for continuous in-cluster scanning, and the Aqua/CNCF backing gives confidence in database update reliability. Trivy is used by [GitHub's container scanning](https://docs.github.com/en/code-security/code-scanning) and [Harbor](https://goharbor.io), among others.

[Falco](https://falco.org) was considered for runtime syscall-level threat detection and deferred. In a homelab environment without per-workload tuned rules, Falco's default ruleset generates enough noise that alerts become background. Trivy's findings are lower noise by nature: a critical CVE in a running image is always actionable. Falco also requires privileged kernel access that Talos's (see [ADR-001](ADR-001-kubernetes.md)) immutable kernel complicates. It is worth revisiting when the workload surface is larger and there is capacity to tune rules.

## Consequences

**Positive:**

- Every workload's network connectivity is explicit and auditable from day one. No undocumented implicit paths.
- Hubble provides flow-level visibility into policy drops, making misconfigured rules diagnosable rather than mysterious.
- CVE findings from Trivy are Kubernetes-native objects (`kubectl get vulnerabilityreports`), compatible with ArgoCD and Kyverno (see [ADR-014](ADR-014-kyverno.md)), and surfaced in the same Grafana/Alertmanager stack as everything else.
- `ConfigAuditReport` CRDs catch misconfigurations (containers running as root, missing resource limits, privileged pods) as a second independent layer alongside Kyverno.

**Negative:**

- Every new workload requires explicit allow rules. This is recurring friction. On a solo homelab it is manageable; it would slow velocity on a shared team.
- Trivy pulls updated vulnerability database archives from GitHub releases daily. This is a named outbound egress dependency that needs an explicit allow rule in the Trivy namespace's `CiliumNetworkPolicy`.
- Alerting on Trivy findings needs a sensible threshold. The practical configuration is to alert on critical severity CVEs and surface medium/low findings in Grafana dashboards for periodic review. Alerting on everything trains operators to ignore alerts.
- NetworkPolicy and Trivy do not cover Role-Based Access Control (RBAC) permissions or secrets posture. Whether service accounts are over-permissioned and whether secrets are mounted only where needed is a separate audit, documented as part of the [Phase 8](../../README.md#phases) security pass.
