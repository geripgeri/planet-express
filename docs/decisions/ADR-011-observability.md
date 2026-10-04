# ADR-011: Self-Hosted Observability with Prometheus, Loki, and Tempo

## Status

Active

## Context

A single-node Kubernetes homelab running Talos Linux on Proxmox with stateful workloads (CNPG databases, Immich photo library, Longhorn volumes) has no tolerance for silent failures. Without observability, problems surface only when a service stops responding. See [ADR-000](ADR-000-project-goals.md) for the goals that set this context.

The constraints are narrower than in a production multi-cluster environment:

- 30-day metric retention is enough. No compliance requirement, no long-term trend analysis
- Log volume is low: a handful of workloads, no high-throughput event pipeline
- No application-level tracing yet, but the infrastructure should be ready for it
- Observability data is reproducible, so losing history costs nothing of consequence
- One operator. If the stack needs constant attention, it is not doing its job

**Managed services were rejected.** [Datadog](https://www.datadoghq.com/) and [Grafana Cloud](https://grafana.com/products/cloud/) solve the infrastructure problem, but:

- Data sovereignty: cluster metrics expose pod names, namespace structure, resource consumption, and node topology. Log streams may hold usernames, paths, and internal error detail. Shipping that to a third party by default is a deliberate choice, not a neutral one
- Portfolio value: configuring [Prometheus](https://prometheus.io/) [`ServiceMonitor`](https://prometheus-operator.dev/docs/operator/api/#monitoring.coreos.com/v1.ServiceMonitor) resources, writing recording rules, building a [Loki](https://grafana.com/oss/loki/) log pipeline, and wiring [Alertmanager](https://prometheus.io/docs/alerting/latest/alertmanager/) routes is directly applicable professional knowledge. Clicking through a managed onboarding wizard is not
- Cost: Datadog is priced for teams, and Grafana Cloud's free tier is more generous but still scoped for evaluation rather than ongoing operation

**[VictoriaMetrics](https://victoriametrics.com/)** was evaluated as a Prometheus replacement. Its compression and memory efficiency arguments are real, but [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack) bundles pre-configured `ServiceMonitor`s, recording rules, and dashboards calibrated for Prometheus, and current cluster utilisation makes that trade-off not worth taking.

**[Elastic Stack](https://www.elastic.co/elastic-stack)** was rejected on resource grounds before any other consideration. [Elasticsearch](https://www.elastic.co/elasticsearch) needs a 2-4GB heap minimum, which is not justified on a cluster sharing 32GB RAM with Longhorn, CNPG, Authentik, and other workloads. Loki's label-based indexing covers these query patterns at an order of magnitude lower resource cost.

**[Jaeger](https://www.jaegertracing.io/)** was considered for traces. **[Grafana Tempo](https://grafana.com/oss/tempo/)** won on Grafana integration: one interface to correlate a metric spike to the matching Loki log lines to the matching Tempo trace, with no tool switching and no second authentication context. Jaeger also needs Elasticsearch or [Cassandra](https://cassandra.apache.org/) as a storage backend, which adds operational weight.

**[Promtail](https://grafana.com/docs/loki/latest/send-data/promtail/)** reached End-of-Life (EOL) on March 2, 2026 and is unsupported, so it is unsuitable long-term even for Loki alone. The [OpenTelemetry (OTel) Collector](https://opentelemetry.io/docs/collector/) won on consolidation: one agent DaemonSet instead of separate Promtail and trace collector deployments, one pipeline to maintain, and alignment with the CNCF instrumentation standard that future application tracing will target, see [ADR-002](ADR-002-opentofu-terragrunt.md) for the CNCF governance stance.

## Decision

I will deploy a three-signal observability stack: **[kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)** (Prometheus, [Grafana](https://grafana.com/), Alertmanager, [kube-state-metrics](https://github.com/kubernetes/kube-state-metrics), [node-exporter](https://github.com/prometheus/node_exporter)), **Loki**, **Grafana Tempo**, and the **[OpenTelemetry Operator](https://opentelemetry.io/docs/platforms/kubernetes/operator/)** as the unified collection pipeline.

All observability PVCs use the `longhorn-single-replica` StorageClass (see [ADR-007](ADR-007-longhorn.md)). The data is reproducible, so single-replica is correct.

Key configuration decisions:

- **Prometheus**: 30-day retention on a `longhorn-single-replica` PVC. Talos node metrics need a [`ScrapeConfig`](https://prometheus-operator.dev/docs/api-reference/api/#monitoring.coreos.com/v1alpha1.ScrapeConfig) with static targets on port `11234` of each node IP, plus a Cilium (see [ADR-005](ADR-005-cilium-gateway-api.md)) NetworkPolicy permit rule. Proxmox host metrics come from [`pve-exporter`](https://github.com/prometheus-pve/prometheus-pve-exporter) on the Proxmox host as an Ansible-managed systemd service (see [ADR-016](ADR-016-ansible-for-proxmox-host-configuration.md)), with its API token in SOPS (see [ADR-009](ADR-009-sops.md))-encrypted Ansible host vars. Prometheus scrapes it like any other static target
- **Grafana**: Authentik OIDC through [`auth.generic_oauth`](https://grafana.com/docs/grafana/latest/setup-grafana/configure-security/configure-authentication/generic-oauth/), not forward auth proxy. Native OIDC is the right pattern for apps that support it (Grafana, ArgoCD (see [ADR-003](ADR-003-argocd.md)), Proxmox), because it preserves role mapping and group sync that the proxy path loses
- **Loki**: `replication_factor: 1` (correct for a single Loki instance), local filesystem backend on a `longhorn-single-replica` PVC. Garage (see [ADR-010](ADR-010-garage.md)) S3 is the upgrade path if retention or volume requirements grow
- **Tempo**: local filesystem backend. No application instrumentation yet, and the collector deploys now so traces are available when needed instead of requiring an infrastructure retrofit later
- **OTel Operator**: DaemonSet-mode collector for node-level log and metric collection, plus a separate Deployment-mode collector that receives traces from instrumented applications and forwards them to Tempo

## Consequences

**Positive:**

- Metrics, logs, and traces in one Grafana interface, with native time-based correlation between signals
- Running the full stack from kube-prometheus-stack through OTel Collector configuration draws on existing, hands-on infrastructure experience
- All observability PVCs rebuild from scratch in under an hour with no meaningful data loss
- OTel infrastructure is ready for application-level tracing (n8n, Immich) when [Phase 12](../../README.md#phases) work begins, with no further collector changes needed
- VictoriaMetrics (metrics) and Garage S3 (Loki chunks) are clean upgrade paths if resource or retention requirements change

**Negative / accepted trade-offs:**

- The observability stack can go down silently, removing visibility into the cluster at the moment it is most needed. Alertmanager is configured to fire on absence of scrape data from critical targets, which catches most silent failures. The irony is accepted and documented
- Talos node metrics need explicit `ScrapeConfig` targeting and Cilium NetworkPolicy rules. The default kube-prometheus-stack install does not cover this, and both need maintenance as node configuration changes
- Grafana's OIDC integration with Authentik requires keeping `auth.generic_oauth` values in sync with the Authentik application config. Drift there breaks Grafana login
- No application-level traces yet. Infrastructure telemetry (Kubernetes events, Cilium metrics) populates Tempo first, and meaningful traces need instrumentation work that is out of scope for this phase
