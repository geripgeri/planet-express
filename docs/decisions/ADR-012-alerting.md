# ADR-012: Alert Delivery via Signal and signal-cli-rest-api

## Status

Accepted

## Context

The observability stack (Prometheus, Alertmanager, Grafana — see [ADR-011](ADR-011-observability.md) for details) is in place. The remaining gap is last-mile alert delivery: getting a firing alert to a human reliably.

The constraints for this homelab are:

- **Solo operator.** No on-call rotation, no escalation path. Alerts must reach one person on a personal device.
- **Mobile push required.** The most likely scenario for a firing alert is being away from a desk. The channel must push to a phone, not require polling a dashboard.
- **Low infrastructure dependency.** The alert delivery path should not depend on the services being monitored. A channel that routes through in-cluster infrastructure shares fate with the things it reports on.
- **No vendor lock-in on a critical path.** A commercial SaaS changing pricing or terms should not break alerting.

Incident Response Management (IRM) platforms ([PagerDuty](https://www.pagerduty.com), [OpsGenie](https://www.atlassian.com/software/opsgenie), [Grafana OnCall](https://grafana.com/products/oncall/)) are out of scope by design. They exist for teams with escalation policies, acknowledgement workflows, and on-call schedules. For a solo operator, the incident response workflow is: see the notification, decide whether to act now or in the morning, act. There is no escalation path. The complexity of IRM adds nothing here.

Two candidates were ruled out before evaluation:

- **[Grafana OnCall OSS](https://github.com/grafana/oncall)** was archived in March 2026. The repository is read-only with no further security patches or development. Deploying freshly archived infrastructure as a core alerting component is not a reasonable choice.
- **OpsGenie** has a published end-of-life (EOL) date in 2027. Building on a platform with a known wind-down date forces a migration regardless of whether you want one.

Email was rejected as a primary channel because it has pull semantics: the alert waits in a queue until you check, rather than interrupting. Slack was rejected because it is a SaaS dependency on the alert path and its free tier trajectory under Salesforce ownership is uncertain. Telegram was passed over because end-to-end (E2E) encryption is opt-in rather than default, which conflicts with the preference for platforms that are private by design. ntfy self-hosted was rejected because it runs inside the cluster and shares fate with the infrastructure it would report on. Pushover was rejected because it is a small commercial SaaS with no open-source fallback.

[Signal](https://signal.org) addresses all of these concerns directly. It is E2E encrypted by default using a published, audited protocol. The client is open source. The service is operated by a non-profit. The [signal-cli-rest-api](https://github.com/bbernhard/signal-cli-rest-api) project wraps [signal-cli](https://github.com/AsamK/signal-cli) in a REST API, giving Alertmanager's `webhook_configs` receiver a clean integration point with no custom code required.

The shared-fate concern applies here too: signal-cli-rest-api runs inside the cluster. On single-host hardware, however, there is no "outside the cluster" that is meaningfully more reliable. Both live on the same physical machine. The failure modes that would simultaneously take down signal-cli-rest-api and Alertmanager's routing are the same failure modes that prevent any delivery path from working. The in-cluster deployment does not materially change the reliability picture for this topology.

## Decision

I will route alerts through Alertmanager's `webhook_configs` receiver to a signal-cli-rest-api instance running as a Kubernetes deployment in the `observability` namespace, delivering push notifications to a personal Signal account.

signal-cli-rest-api is deployed with a ClusterIP service on port 8080. No external exposure is required. Alertmanager targets `http://signal-cli-rest-api.observability.svc:8080/v2/send`.

```yaml
alertmanager:
  config:
    receivers:
      - name: signal
        webhook_configs:
          - url: 'http://signal-cli-rest-api.observability.svc:8080/v2/send'
            send_resolved: true
            http_config:
              bearer_token_file: /var/run/secrets/alertmanager/token
    route:
      receiver: signal
      group_by: ['alertname', 'namespace']
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 4h
```

`send_resolved: true` sends a follow-up notification when a firing alert clears. The grouping and repeat intervals are conservative by design: one notification when something starts firing, one when it clears, and a periodic reminder if it stays open. A homelab does not need sub-minute alerting latency.

The sending phone number must be registered with Signal after initial deployment. This step requires an SMS verification code and cannot be automated, but can be performed via the REST API, no `kubectl exec` into the container is required. It is documented in the [Phase 6](../../README.md#phases) runbook. Registration data is persisted to a Longhorn (see [ADR-007](ADR-007-longhorn.md)) 3-replica PVC (not `longhorn-single-replica`) to survive pod restarts without requiring re-registration.

## Consequences

**Positive:**

- Push notifications arrive on a personal mobile device within seconds of an alert firing, with no intermediate SaaS dependency beyond Signal's own infrastructure.
- `send_resolved: true` confirms when a condition clears, eliminating the need to poll Grafana to verify recovery.
- Alertmanager grouping prevents notification storms during flapping conditions.
- signal-cli-rest-api is a standard Kubernetes workload: Renovate (see [ADR-004](ADR-004-renovate.md)) bumps the image, ArgoCD (see [ADR-003](ADR-003-argocd.md)) reconciles it, the same operational patterns apply as for every other app in the cluster.
- Alert payloads (hostnames, IPs, service names) are E2E encrypted in transit. Signal's infrastructure cannot read them.

**Negative:**

- No IRM workflows: no acknowledgement, no escalation, no runbook links in the notification. Not a gap for a solo operator; would be for a team.
- Alert delivery depends on the cluster being healthy enough to route. If Alertmanager itself cannot reach the webhook endpoint, no alerts are delivered regardless of the endpoint chosen. A truly independent delivery path (a sidecar process on the Proxmox host, for example) would be more resilient but adds significant complexity for marginal gain on single-host hardware.
- Signal message history is not indexed or searchable. Post-incident review of "all alerts over the past 72 hours" comes from Alertmanager's storage and Grafana, not from the message thread.
