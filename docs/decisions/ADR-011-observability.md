# ADR-011: Self-Hosted Observability with Prometheus, Loki, and Tempo

## Status

Active

## Context

A single-node Kubernetes homelab running Talos Linux (see [ADR-001](ADR-001-kubernetes.md)) on Proxmox (see [ADR-000](ADR-000-project-goals.md)) with stateful workloads (CNPG databases (see [ADR-006](ADR-006-cloudnativepg.md)), Immich photo library, Longhorn volumes (see [ADR-007](ADR-007-longhorn.md))) has no tolerance for silent failures. Without observability, problems surface only when a service stops responding.

The constraints are narrower than a production multi-cluster environment:

- 30-day metric retention is sufficient. No compliance requirement, no long-term trend analysis.
- Log volume is low. A handful of workloads, no high-throughput event pipeline.
- No application-level tracing yet, but the infrastructure should be ready for it.
- Observability data is reproducible. If the stack loses its history, nothing of consequence is lost.
- One operator. If the observability stack requires constant attention, it isn't doing its job.

**Managed services were rejected.** [Datadog](https://www.datadoghq.com/) and [Grafana Cloud](https://grafana.com/products/cloud/) both solve the infrastructure problem, but:

- Data sovereignty: cluster metrics expose pod names, namespace structure, resource consumption patterns, and node topology. Log streams may contain usernames, paths, and internal error detail. Shipping this to a third party by default is a deliberate choice, not a neutral one.
- Portfolio value: configuring [Prometheus](https://prometheus.io/) [`ServiceMonitor`](https://prometheus-operator.dev/docs/operator/api/#monitoring.coreos.com/v1.ServiceMonitor) resources, writing recording rules, building a [Loki](https://grafana.com/oss/loki/) log pipeline, and wiring [Alertmanager](https://prometheus.io/docs/alerting/latest/alertmanager/) routes is directly applicable professional knowledge. Clicking through a managed onboarding wizard is not.
- Cost: Datadog is priced for teams. Grafana Cloud's free tier is more generous but still scoped for evaluation rather than ongoing operation.

**[VictoriaMetrics](https://victoriametrics.com/)** was evaluated as a Prometheus replacement. Its compression and memory efficiency arguments are real, but [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack) bundles pre-configured `ServiceMonitor`s, recording rules, and dashboards calibrated for Prometheus. Current cluster utilisation makes the trade-off not worth it. VictoriaMetrics is the clear upgrade path if Prometheus RAM usage becomes a problem.

**[Elastic Stack](https://www.elastic.co/elastic-stack)** was rejected on resource grounds before any other consideration. [Elasticsearch](https://www.elastic.co/elasticsearch) needs 2-4GB heap minimum. On a cluster sharing 32GB RAM with Longhorn, CNPG, Authentik (see [ADR-008](ADR-008-authentik.md)), and other workloads, that allocation isn't justified. Loki's label-based indexing covers the query patterns here at an order of magnitude lower resource cost.

**[Jaeger](https://www.jaegertracing.io/)** was considered for traces. [Grafana Tempo](https://grafana.com/oss/tempo/) won on Grafana integration: a single interface to correlate a metric spike to the corresponding Loki log lines to the corresponding Tempo trace, without switching tools or authentication contexts. Jaeger also requires Elasticsearch or [Cassandra](https://cassandra.apache.org/) as a storage backend, which adds operational weight.

**[Promtail](https://grafana.com/docs/loki/latest/send-data/promtail/)** reached End-of-Life (EOL) on March 2, 2026 and is no longer supported, making it unsuitable as a long-term solution even for Loki alone. The [OpenTelemetry (OTel) Collector](https://opentelemetry.io/docs/collector/) was preferred for consolidation: one agent DaemonSet instead of separate Promtail and trace collector deployments, one pipeline to maintain, and alignment with the CNCF (see [ADR-002](ADR-002-opentofu-terragrunt.md)) instrumentation standard that future application tracing will target.

## Decision

I will deploy a three-signal observability stack: **[kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)** (Prometheus, [Grafana](https://grafana.com/), Alertmanager, [kube-state-metrics](https://github.com/kubernetes/kube-state-metrics), [node-exporter](https://github.com/prometheus/node_exporter)), **Loki**, **Grafana Tempo**, and the **[OpenTelemetry Operator](https://opentelemetry.io/docs/platforms/kubernetes/operator/)** as the unified collection pipeline.

All observability PVCs use the `longhorn-single-replica` StorageClass (see [ADR-007](ADR-007-longhorn.md)). Observability data is reproducible; single-replica is correct.

Key configuration decisions:

- **Prometheus**: 30-day retention on a `longhorn-single-replica` PVC. Talos node metrics require a [`ScrapeConfig`](https://prometheus-operator.dev/docs/api-reference/api/#monitoring.coreos.com/v1alpha1.ScrapeConfig) with static targets on port `11234` of each node IP, plus a Cilium (see [ADR-005](ADR-005-cilium-gateway-api.md)) NetworkPolicy permit rule. Proxmox host metrics come from [`pve-exporter`](https://github.com/prometheus-pve/prometheus-pve-exporter) running on the Proxmox host as an Ansible-managed systemd service (see [ADR-016](ADR-016-ansible-for-proxmox-host-configuration.md)), with its API token stored in SOPS (see [ADR-009](ADR-009-sops.md))-encrypted Ansible host vars. Prometheus scrapes it like any other static target.
- **Grafana**: Authentik OIDC integrated directly via [`auth.generic_oauth`](https://grafana.com/docs/grafana/latest/setup-grafana/configure-security/configure-authentication/generic-oauth/), not forward auth proxy. Native OIDC is the right pattern for apps that support it (Grafana, ArgoCD (see [ADR-003](ADR-003-argocd.md)), Proxmox); it preserves role mapping and group sync that the proxy path would lose.
- **Loki**: `replication_factor: 1` (correct for a single Loki instance), local filesystem backend on a `longhorn-single-replica` PVC. S3 via Garage (see [ADR-010](ADR-010-garage.md)) is the natural upgrade path if retention or volume requirements grow.
- **Tempo**: local filesystem backend. No application instrumentation yet; the collector is deployed now so traces are available when needed rather than requiring an infrastructure retrofit later.
- **OTel Operator**: DaemonSet-mode collector for node-level log and metric collection; separate Deployment-mode collector for receiving traces from instrumented applications and forwarding to Tempo.

## Consequences

**Positive:**

- Metrics, logs, and traces are available in a single Grafana interface with native time-based correlation between signals.
- Running the full stack from kube-prometheus-stack through OTel Collector configuration draws on existing, hands-on infrastructure experience.
- All observability PVCs can be rebuilt from scratch in under an hour with no meaningful data loss.
- OTel infrastructure is ready for application-level tracing (n8n, Immich) when [Phase 11](../../README.md#phases) work begins, with no further collector changes required.
- VictoriaMetrics (metrics) and Garage S3 (Loki chunks) are clean upgrade paths if resource or retention requirements change.

**Negative / accepted trade-offs:**

- The observability stack can go down silently, removing visibility into the cluster at the moment it's most needed. Alertmanager is configured to fire on absence of scrape data from critical targets, which catches most silent failures. The irony is accepted and documented.
- Talos node metrics require explicit `ScrapeConfig` targeting and Cilium NetworkPolicy rules. This is not covered by the default kube-prometheus-stack install and must be maintained as node configuration changes.
- Grafana's OIDC integration with Authentik requires keeping `auth.generic_oauth` values in sync with the Authentik application config. Drift here breaks Grafana login.
- No application-level traces yet. Infrastructure telemetry (Kubernetes events, Cilium metrics) will populate Tempo first; meaningful traces require instrumentation work that is out of scope for this phase.
