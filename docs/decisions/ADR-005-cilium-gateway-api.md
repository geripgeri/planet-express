# ADR-005: Cilium Gateway API over a Separate Ingress Controller

## Status

Active

## Context

Every service exposed inside the cluster needs HTTP/HTTPS routing: [Grafana](https://grafana.com/), ArgoCD, Authentik, Immich. The traditional answer is an ingress controller watching `kind: Ingress` resources. Two things made that path untenable in 2026.

1. **[ingress-nginx](https://github.com/kubernetes/ingress-nginx) reached end of life in March 2026.** No further security patches, so deploying it means accumulating unpatched CVEs in a stack that runs [Trivy Operator](https://aquasecurity.github.io/trivy-operator/), Kyverno, and Renovate. Rejected, and it would need a second proxy alongside Cilium.

2. **The `Ingress` API is frozen.** Upstream Kubernetes has blessed [Gateway API](https://gateway-api.sigs.k8s.io/) as the successor, and no new features are planned for `kind: Ingress`. Its annotation-based extension model (controller-specific `nginx.ingress.kubernetes.io/*` annotations, no role separation, no L4/L7 composition) is a dead end.

[Gateway API](https://gateway-api.sigs.k8s.io/) ([GA since v1.0, October 2023](https://kubernetes.io/blog/2023/10/31/gateway-api-ga/)) solves this with a structured resource hierarchy: [`GatewayClass`](https://gateway-api.sigs.k8s.io/api-types/gatewayclass/) for cluster-level implementation, [`Gateway`](https://gateway-api.sigs.k8s.io/api-types/gateway/) for listeners and TLS, [`HTTPRoute`](https://gateway-api.sigs.k8s.io/api-types/httproute/) for per-service routing. Ownership boundaries are explicit. No annotations.

[Cilium](https://cilium.io/) was already the cluster CNI (see [ADR-013](ADR-013-cilium-network-policy.md) for NetworkPolicy enforcement and the Trivy Operator scanning that sit alongside it), managing pod networking, BGP/L2 load balancing, and DNS integration. It has included native Gateway API support since [Cilium 1.13](https://github.com/cilium/cilium/releases/tag/v1.13.0), in the same Helm chart and DaemonSet pods.

**Alternatives considered:**

- **[Traefik](https://traefik.io/)**: Actively maintained, good middleware system. Rejected for the same reason: a second L7 proxy duplicating what Cilium already does. The right choice if Cilium were not the CNI
- **[Envoy Gateway](https://gateway.envoyproxy.io/)**: CNCF reference implementation, clean architecture, strong upstream backing. Rejected for the same reason as Traefik
- **[Istio](https://istio.io/)**: Parked but not rejected. Cilium's own service mesh features (mTLS, L7 policy) are developing. Revisit after the stack is stable, because adding a service mesh before understanding baseline cluster behaviour makes debugging harder

## Decision

I will use Cilium's built-in Gateway API controller for all HTTP/HTTPS routing. No separate ingress controller will be deployed.

All services attach to a single shared `Gateway` in `kube-system`, terminating TLS with a wildcard cert (`*.yourdomain.internal`) provisioned by cert-manager (see [ADR-000](ADR-000-project-goals.md)) via DNS-01. Application teams write only an `HTTPRoute` specifying the hostname and backend service, and manage no TLS configuration.

Non-OIDC services use Authentik forward authentication via the `ExtensionRef` filter on `HTTPRoute`. Services with native OIDC support (Grafana, ArgoCD, Proxmox) configure their own Authentik integration and do not use `ExtensionRef`.

## Consequences

**Positive:**

- No `kind: Ingress` in this cluster. All routing uses stable, upstream-invested Gateway API resources
- L3/L4 networking, load balancing, NetworkPolicy, and L7 routing are owned by one component, so connectivity debugging has one place to look, not two
- TLS management is centralised at the Gateway. Applications need minimal `HTTPRoute` resources with no cert or listener configuration, and Gateway API arrives with a Cilium chart upgrade Renovate already manages, not as a separate dependency

**Negative / trade-offs:**

- The `ExtensionRef` integration for Authentik forward auth is still maturing, and the CRD and configuration syntax has changed between Cilium minor versions. Verify the exact configuration against the Cilium version deployed at the time, and do not copy from pre-1.14 sources without checking. This is flagged as a verification step in [Phase 3.5](../../README.md#phases)
- Cilium Gateway API is less feature-complete than nginx or Traefik for advanced routing (complex header manipulation, per-route timeout granularity). That has not constrained the current service set, but unusual routing requirements in a future service call for a fresh evaluation
- Gateway API behaviour changes between Cilium minor versions, so Renovate-managed chart bumps need a changelog review before automerge
