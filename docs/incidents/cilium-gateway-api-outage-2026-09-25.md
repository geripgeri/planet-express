# Post-mortem: Gateway API ingress outage after the Cilium 1.20.2 chart upgrade, 2026-09-25

- **Date**: 2026-09-25
- **Status**: Resolved, fix merged except the operator rollout lever
- **Component**: Cilium operator (Gateway API control plane) vs the pinned Gateway API CRD bundle
- **Severity**: Total HTTPS ingress outage. Every hostname on the shared Gateway was unreachable.
- **Duration**: ~2 h 07 min, from the chart upgrade (15:57 UTC) to route re-acceptance (18:06 UTC)
- **User impact**: None observed. The homelab had no active consumers of the affected endpoints, which is the only reason this was found by hand rather than by a user.

## Summary

The Cilium chart upgrade from `1.17.6` to `1.20.2` restarted the operator with a
new startup check. The check requires Gateway API CRDs that this cluster never
had: `tlsroutes` and `referencegrants` served at `v1`, and `backendtlspolicies`
present at all. The pinned bundle was Gateway API `v1.2.1`, which satisfies none
of the three.

The check fails closed. The operator logs one error and then never starts its
Gateway API control plane, so it translates no routes, writes no status, and
feeds Envoy no configuration. Every connection to the Gateway's LoadBalancer
address is reset, on every hostname, for the whole cluster.

Nothing in the cluster reports the fault. Routes keep the status they were
last written with, the Gateway keeps `Programmed=True`, and the ArgoCD
applications stay `Synced/Healthy`. The only evidence is one line in the
operator log, and the stale timestamps on the status objects.

## Timeline

All times UTC.

- **15:57**: `terragrunt apply` upgrades the Cilium chart to `1.20.2`; the
  operator Deployment rolls.
- **15:59:28**: The new operator logs
  `Required GatewayAPI resources are not found, please refer to docs for installation instructions` with
  `tlsroutes.gateway.networking.k8s.io does not have version "v1"`,
  `referencegrants.gateway.networking.k8s.io does not have version "v1"`,
  `backendtlspolicies.gateway.networking.k8s.io not found`, and does not start
  the Gateway API control plane.
- **~16:00**: Ingress breaks. `curl` to any hostname on the Gateway returns
  `Recv failure: Connection reset by peer`. Longhorn UI and Authentik are both
  down. The Longhorn UI outage is the repeat of
  [2026-09-05](talos-rebuild-incident-2026-08-29.md), from a different cause.
- **16:00-17:45**: Misdiagnosis. The Authentik HTTPRoute had no status at all,
  which was read as a cross-namespace reconciliation fault
  (`cilium/cilium#39057`). A co-location workaround was written, merged and
  deployed. It changed nothing, because the controller was not running.
- **17:45**: The longhorn route is inspected: it is cross-namespace too and
  carries `Accepted=True` and `ResolvedRefs=True`. Cross-namespace attachment
  works. The empty status belongs to a controller that is not reconciling at
  all, which is a cluster-wide fault, not a per-route one.
- **17:50**: The operator log is read directly and the precheck failure is
  found. The pinned bundle is Gateway API `v1.2.1`.
- **18:00**: The bundle is replaced with `v1.6.2` (first satisfying release is
  `v1.5.0`) and merged. Routing stays broken: the operator does not re-run the
  precheck, so the new CRDs have no effect on a running pod.
- **18:06**: `operator.rollOutPods = true` is added to the Cilium unit and
  applied. The operator rolls, the precheck passes, and both routes are
  accepted. Longhorn returns `200`, Authentik `302`.

## Root causes

### 1. The chart upgrade raised a CRD floor that nothing in the repository tracked

Cilium 1.20.2 requires Gateway API `v1.5.0` or newer. Gateway API `v1.5.0` is
the first release that serves `tlsroutes` and `referencegrants` at `v1` and
ships `backendtlspolicies`. The bundle in
`kubernetes/infrastructure/private/network/gateway-api-crds.yaml` was `v1.2.1`,
pinned when the cluster was built in August and never revisited.

Nothing connects the two versions. The chart version lives in
`infrastructure/catalogs/public/cilium/vars.tf`, the CRD bundle lives in a
private ArgoCD-managed manifest, and no check compares them. A Renovate chart
bump can therefore raise the floor with no diff in the CRD manifest at all.

### 2. The precheck fails closed, once, at startup

The operator evaluates the CRD requirement when the process starts. On failure
it logs and skips the Gateway API control plane for the lifetime of the pod.
The check is not re-evaluated on a timer and not on CRD changes: after the
`v1.6.2` bundle was applied and the CRD list confirmed correct, routes still had
no status until the operator pod was replaced.

Consequence: the CRD fix alone could not restore service, and the outage
continued for a further six minutes after the correct fix was merged. Without
`operator.rollOutPods`, any future precheck failure is permanent until someone
restarts the operator by hand.

### 3. The failure mode is silent in every status surface

The outage presented as healthy:

- `HTTPRoute` objects kept their last written status. The longhorn route still
  showed `Accepted=True` with `lastTransitionTime` frozen at 2026-08-31.
- The `Gateway` kept `Programmed=True` and a stale address, frozen at
  2026-08-30.
- `cilium-dbg status` knew nothing about the LoadBalancer service.
- ArgoCD reported `Synced/Healthy`, including for the application whose route
  could not work at all.
- The symptom at the HTTP layer was a TCP reset, which looks like a dead
  listener or a wrong address, not like a missing CRD version.

The one honest signal was a brand-new route with a completely empty status
while older routes carried stale status. A newly created object that never gets
status means the controller is not processing objects, not that this object is
malformed.

## Detection

Found by hand, during an unrelated Authentik deployment task.

- `curl` to a Gateway hostname reset, while the same hostname with a direct
  `Host:` header against the Authentik Service backend returned `302`. Backend
  healthy, ingress dead.
- A freshly created `HTTPRoute` had no `status` block at all.
- `kubectl get httproute -A -o wide` showed no address columns, and every
  existing status object carried a `lastTransitionTime` weeks in the past.
- `kubectl -n kube-system logs deploy/cilium-operator | grep -i "Required GatewayAPI"` produced the single decisive line.

## Fixes

- Gateway API CRD bundle bumped `v1.2.1` → `v1.6.2` in
  `kubernetes/infrastructure/private/network/gateway-api-crds.yaml`, with a
  provenance header naming the source URL, the refresh command, and the Cilium
  requirement it satisfies.
- `operator.rollOutPods = true` in
  `infrastructure/catalogs/public/cilium/main.tf`. The chart turns this into a
  `cilium.io/cilium-configmap-checksum` annotation on the operator Deployment,
  so any `cilium-config` change rolls the operator and re-runs the precheck.
- The co-location workaround from the misdiagnosis was reverted: the
  Authentik `HTTPRoute` is back in the `authentik` namespace and the
  `ReferenceGrant` is gone. Cross-namespace attachment works and needs nothing.
- The false cross-namespace claim, its `cilium/cilium#39057` citation, rule
  NET-04 and the runbook row built on it were retracted in the same change that
  documented the real requirement.
- `.pre-commit-config.yaml`: the vendored CRD bundle is exempted from the
  500 KB `check-added-large-files` limit, with the reason inline.
- [ADR-005](../decisions/ADR-005-cilium-gateway-api.md) documents the CRD
  floor, the failure signature and the pre-upgrade check; the Authentik runbook
  gained two failure rows for it.

## Lessons learned

- A chart upgrade can raise a requirement that lives in a different repository
  path, in a different tool, with no diff. Treat the Cilium chart version and
  the Gateway API CRD version as one version pair.
- `Required GatewayAPI resources are not found` is not a warning. It disables
  ingress for the entire cluster, and it is the only line anywhere that says so.
- Stale status objects are not evidence of health. Compare
  `lastTransitionTime` against the time of the last change; a status written
  before an upgrade proves nothing about the current state.
- A new object with an empty status means the controller is down. A new object
  with a *wrong* status means the controller is working and the object is wrong.
- Check a known-good peer before theorising. The longhorn route's status would
  have disproved the cross-namespace theory in the first ten minutes.
- Gateway API CRDs are not installed by the Cilium chart, so nothing reconciles
  them against the chart. That is the actual gap.
- Renovate chart bumps need a pre-upgrade checklist item, not only a changelog
  read: "read the operator's CRD requirement before applying".

## Follow-ups

- [ ] Merge the `fix/cilium-operator-rollout` PR. The cluster currently runs
  the rolled-out operator from a working tree; an apply from `main` without
  `rollOutPods` would silently drop the lever.
- [ ] Add a check that fails when the pinned Gateway API bundle is below the
  version the deployed Cilium chart requires. A script that renders the chart
  and greps the operator's expected CRD versions, run in pre-commit or CI,
  closes the gap that caused this.
- [ ] Add an ingress reachability step (`curl` a known hostname) to the
  post-upgrade verification in the Talos/K3s upgrade runbook, next to the DNS
  check added on 2026-09-20.
- [ ] Find out why the `cilium-network` ArgoCD application reports `Degraded`
  after the CRD bundle update. It was `Synced/Healthy` before.
- [ ] Verify ArgoCD SSO end to end at `https://argocd.example.com` now that
  ingress is back; the original Authentik objective is unverified.
- [ ] Review whether other components have startup-only prechecks with the same
  fail-closed shape.
