# ADR-013: Cilium NetworkPolicy and Trivy Operator as the Cluster Security Layer

## Status

Active

## Context

A Kubernetes cluster running real workloads has a meaningful attack surface. Containers escape. Dependencies carry Common Vulnerabilities and Exposures (CVEs). Misconfigured service accounts grant more access than intended. Images pulled months ago carry unpatched vulnerabilities in their base layers.

This ADR covers two of the three components in the cluster security layer: network traffic control (Cilium (see [ADR-005](ADR-005-cilium-gateway-api.md)) NetworkPolicy) and vulnerability scanning ([Trivy Operator](https://aquasecurity.github.io/trivy-operator/)). The third component, Kyverno, is in [ADR-014](ADR-014-kyverno.md). Each layer catches a different class of problem independently, so a gap in one is not a gap everywhere. The cluster runs Cilium as its CNI, Renovate (see [ADR-004](ADR-004-renovate.md)) handles proactive dependency bumps through PRs, and the Prometheus/Grafana/Alertmanager stack is in place for metrics and alerting (see [ADR-011](ADR-011-observability.md)).

## Decision

**Cilium NetworkPolicy:** Every namespace gets a default-deny `CiliumNetworkPolicy` at creation time, not retroactively and not batched into a later security phase. Each workload's allow rules deploy alongside its own manifests.

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

All ingress is denied by default. Egress is denied except for DNS, a required carveout: without it, service name resolution fails silently in ways that are hard to diagnose. Both TCP and UDP rules on port 53 must be allowed, because CoreDNS answers large responses (SRV records, long TXT records) with the truncation (TC) bit set over UDP and expects the client to retry over TCP, which would be dropped if only UDP 53 is permitted.

`CiliumNetworkPolicy` CRDs are used instead of standard `networking.k8s.io/v1 NetworkPolicy` for three reasons. First, Layer 7 (L7) policy: standard NetworkPolicy operates at Layer 3/Layer 4 (L3/L4) only, while Cilium's CRDs support path-level HTTP rules and DNS-name-based egress, which is the right abstraction for fine-grained service-to-service controls. Second, [Hubble](https://docs.cilium.io/en/stable/overview/intro/) integration: when a policy denies a connection, Hubble shows the drop with full context (source endpoint, destination endpoint, matched rule), turning "something is broken" into "the Prometheus scraper is denied ingress because the allow rule references the wrong label selector." Third, no additional component: Cilium is already the CNI and the policy engine.

Batching default-deny into a later security phase has a specific failure mode. Workloads deployed before it applies may rely on implicit connectivity that was never documented, so applying retroactive restrictions to a running system means discovering undocumented connections by breaking them. Applying default-deny at namespace creation reverses that: every workload must declare its connectivity requirements before it can talk to anything. [Phase 8](../../README.md#phases) stays a meaningful audit-and-tighten pass, covering cross-namespace paths for Prometheus scraping, ArgoCD (see [ADR-003](ADR-003-argocd.md)) sync, Authentik (see [ADR-008](ADR-008-authentik.md)) forward auth, CNPG (see [ADR-006](ADR-006-cloudnativepg.md)) replication, and Longhorn (see [ADR-007](ADR-007-longhorn.md)) CSI.

**Trivy Operator:** [Trivy Operator](https://aquasecurity.github.io/trivy-operator/) runs as a Kubernetes controller that continuously scans workload images and configurations, generating `VulnerabilityReport` and `ConfigAuditReport` CRDs per workload. A Prometheus `ServiceMonitor` scrapes Trivy's metrics endpoint, and a Grafana dashboard surfaces CVE counts by severity and workload over time.

Renovate and Trivy are complementary, not redundant. Renovate is proactive and git-aware: it opens PRs to bump chart and image versions before a vulnerable image is deployed, and it does not know what runs in the cluster. Trivy is reactive and in-cluster: it scans what actually runs against the Trivy vulnerability database, which catches zero-days and newly published CVEs in already-deployed images and detects drift between git and the cluster (manual tag bumps, digest-pinned images, Helm values Renovate cannot track).

Trivy is chosen over [Grype](https://github.com/anchore/grype) and [Snyk](https://snyk.io) because it needs no external account or API key, the Trivy Operator is purpose-built for continuous in-cluster scanning, and Aqua/CNCF backing gives confidence in database update reliability. [GitHub's container scanning](https://docs.github.com/en/code-security/code-scanning) and [Harbor](https://goharbor.io) also use Trivy, among others.

[Falco](https://falco.org) was considered for runtime syscall-level threat detection and deferred. In a homelab without per-workload tuned rules, Falco's default ruleset generates enough noise that alerts become background, while Trivy's findings are lower noise by nature, since a critical CVE in a running image is always actionable. Falco also needs privileged kernel access, which Talos's (see [ADR-001](ADR-001-kubernetes.md)) immutable kernel complicates. It is worth revisiting when the workload surface is larger and there is capacity to tune rules.

## Consequences

**Positive:**

- Every workload's network connectivity is explicit and auditable from day one, with no undocumented implicit paths
- Hubble gives flow-level visibility into policy drops, which makes misconfigured rules diagnosable instead of mysterious
- Trivy CVE findings are Kubernetes-native objects (`kubectl get vulnerabilityreports`), compatible with ArgoCD and Kyverno (see [ADR-014](ADR-014-kyverno.md)), and surface in the same Grafana/Alertmanager stack as everything else
- `ConfigAuditReport` CRDs catch misconfigurations (containers running as root, missing resource limits, privileged pods) as a second independent layer alongside Kyverno

**Negative:**

- Every new workload needs explicit allow rules. That is recurring friction, manageable on a solo homelab but a velocity drag on a shared team
- Trivy pulls updated vulnerability database archives from GitHub releases daily, a named outbound egress dependency that needs an explicit allow rule in the Trivy namespace's `CiliumNetworkPolicy`
- Alerting on Trivy findings needs a sensible threshold. The practical configuration alerts on critical severity CVEs and surfaces medium/low findings in Grafana dashboards for periodic review, because alerting on everything trains operators to ignore alerts
- NetworkPolicy and Trivy do not cover Role-Based Access Control (RBAC) permissions or secrets posture. Whether service accounts are over-permissioned and whether secrets are mounted only where needed is a separate audit, documented as part of the [Phase 8](../../README.md#phases) security pass
