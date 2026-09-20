# ADR-023: Pin coreDNS Upstream — an Interim Keeper CronJob, then Kyverno

## Status

Accepted (2026-09-20), amended to interim CronJob (2026-09-20)

## Context

Cluster DNS broke after the Talos v1.13.9 → v1.14.0 / K8s 1.35.8 → 1.37.0
upgrade. Every ArgoCD application went `Unknown`, cert-manager stalled, and
the GitOps loop stopped. The initial suspect was gitea, but the failure was
structural and upstream of ArgoCD.

Two distinct faults surfaced:

1. **coreDNS could not reach any upstream.** coreDNS uses `dnsPolicy: Default`,
   so kubelet fills its `resolv.conf` with the node resolver. After the
   upgrade kubelet handed pods the address `169.254.116.108` — the Talos
   hostDNS link-local socket. No daemon answers behind that address (a
   direct query from a `dnsPolicy: Default` pod timed out), so coreDNS
   returned SERVFAIL / empty answers for every name, internal
   (`gitea.yourdomain.internal`) and external (`google.com`) alike.

   Root cause: Talos v1.14 enables `hostDNS` by default (`enabled: true`,
   `forwardKubeDNSToHost: true` in the applied config). Talos ≤ v1.13
   defaulted it off, so `dnsPolicy: Default` pods used `/etc/resolv.conf`
   and DNS worked. v1.14+ points them at a socket with nothing serving it.

2. **A misleading secondary symptom.** While probing recovery, some queries
   via coreDNS returned NOERROR with zero answers while the same lookup from
   a `busybox` pod against the internal resolver directly returned the
   record. This was not a cluster fault: AdGuard Home rate-limits per `/24`
   and briefly returned empty answers during the probe burst. Direct queries
   always worked.

Split-horizon DNS is foundational here: the internal record for gitea
(`192.0.2.100`) exists only inside the LAN, and every ArgoCD app fetches
its manifests from gitea. A broken cluster DNS therefore equals a broken
GitOps loop.

### Machine config levers tried and rejected

- **Patch `cluster.hostDNS.enabled: false`.** Talos v1.14 moved hostDNS
  config out of the v1alpha1 block into the `ResolverConfig` document
  ("HostDNS configuration has been moved ... to the new hostDNS section of
  the ResolverConfig document"). The old key no longer exists: the provider
  rejects it with `unknown keys found during decoding: cluster: hostDNS`.
- **Pin `machine.kubelet.resolvConf` / `extraConfig.resolvConf` /
  `extraArgs["resolv-conf"]`.** The `machine.kubelet.resolvConf` form is
  rejected by the provider v0.11.0 decoder. The `extraConfig` and
  `extraArgs` forms decode, but after apply + reboot the `dnsPolicy: Default` pod still reported `nameserver 169.254.116.108`: Talos hostDNS
  rewrites the kubelet resolver config at boot and no user kubelet key
  survives it.
- **Disable hostDNS via the `ResolverConfig` document.** Requires the
  `0.12.0` provider line: v0.11.0 cannot encode the document. With the
  provider `0.12.0-rc.0` the plan decodes, but the apply is rejected by the
  nodes: v1.14 clusters persist the new-style documents (ResolverConfig,
  UnattendedInstallConfig, KubeNetworkConfig, KubePrismConfig,
  KubeProxyConfig), and applying any v1alpha1-style config that still
  carries the old keys (`.machine.install`, `.machine.network.nameservers`,
  `.machine.cluster.network`, `.machine.features.kubePrism`,
  `.machine.cluster.proxy`, `.machine.kubelet`) fails with "cannot be used
  with ... document" conflicts. The full migration to v1.14 documents is a
  separate, large rework of the talos catalog — not something to chain onto
  an incident fix.
- **Kyverno mutation of the coreDNS Corefile.** coreDNS's upstream comes
  from its ConfigMap, which Talos re-renders from its addon. A Kyverno
  `ClusterPolicy` mutating the `coredns` ConfigMap (kube-system) to pin the
  `forward .` upstream on every create/update admission makes the fix
  durable: any Talos re-render during a future upgrade is re-mutated
  immediately, and coreDNS reloads on ConfigMap change. Needs zero machine
  config churn and self-heals. **Deferred**: Kyverno is planned ([ADR-014](ADR-014-kyverno.md))
  but not yet installed in this cluster — no CRDs, no helm app. Installing
  it is a separate deliverable, so the interim fix below lands first.

## Decision

While Kyverno is not yet installed, pin the upstream with an interim
**keeper CronJob**, `kubernetes/infrastructure/private/coredns-upstream/ cronjob.yaml`, that re-applies the desired Talos-rendered `coredns`
ConfigMap (a `kubectl apply` of a fixed Corefile with `forward . <resolver1> <resolver2>`, the same upstream the manual incident patch used) every 5
minutes. Any Talos re-render of the ConfigMap during a future upgrade is
replaced within 5 minutes; coreDNS reloads on ConfigMap change. The path is
export-ignored so the real LAN resolver addresses never reach the public
mirror; the published docs (this ADR, the incident report, the runbook)
demonstrate the mechanism with TEST-NET example addresses.

**Once Kyverno is installed ([ADR-014](ADR-014-kyverno.md) follow-up), delete the CronJob and
adopt the ClusterPolicy instead** (acts at admission time, target
Convergence in seconds). The operative policy form, for reproduction:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: coredns-upstream
spec:
  background: false
  rules:
    - name: pin-corefile-forward-upstream
      match:
        any:
          - resources:
              kinds:
                - ConfigMap
              names:
                - coredns
              namespaces:
                - kube-system
      mutate:
        patchStrategicMerge:
          data:
            Corefile: |
              .:53 {
                  errors
                  health
                  ready
                  kubernetes cluster.local in-addr.arpa ip6.arpa {
                      pods insecure
                      fallthrough in-addr.arpa ip6.arpa
                  }
                  prometheus :9153
                  forward . 192.0.2.100 192.0.2.1
                  cache 30
                  loop
                  reload
                  loadbalance
              }
```

The Corefile must keep the `ready` plugin: Talos's coreDNS Deployment
readiness probe hits `:8181/ready`, which only exists when `ready` is in
the Corefile. Replacing the Corefile without `ready` makes coreDNS run but
never Ready, so the `kube-dns` endpoints empty and every pod loses DNS —
worse than the original fault (a regression found during this work).

Both mechanisms share the same private/export-ignored placement and need
the same ArgoCD private-app source wiring: the keeper's `coredns-upstream`
directory now, the policies path when the ClusterPolicy lands.

The machine config stays untouched: the talos provider remains on the
`0.11.0` pin and hostDNS stays `enabled: true` on the nodes, but it is
inert for pod DNS because the keeper's Corefile sends every upstream query
straight to the resolvers, never to the dead link-local socket. The manual
ConfigMap patch applied during the incident is replaced by the keeper's
managed generation.

## Consequences

**Positive**

- Durable across upgrades: any Talos re-render of the ConfigMap is replaced
  by the keeper within 5 minutes; no operator re-apply step.
- Lands today: needs no new component, no admission controller, and no
  machine config churn on the most critical unit of the repository (talos
  machine config, provider pin, machine secrets).
- GitOps-managed by ArgoCD via the private apps tree; plain manifests, no
  two-step model.
- The manual incident patch (currently only a live, untracked ConfigMap
  edit) is replaced by repo-tracked state; no drift on the next Talos
  re-render.

**Negative**

- The keeper hardcodes the full Corefile, so future upstream changes to the
  Talos default coreDNS plugin set must be updated in the keeper (and in
  the later ClusterPolicy) too.
- Convergence is poll-based, not event-based: after a re-render, cluster
  DNS stays broken for up to 5 minutes until the next run. The later
  Kyverno policy closes this gap (admission-time, seconds).
- The keeper is an extra moving part (CronJob + RBAC + ServiceAccount) that
  must be torn down once the ClusterPolicy takes over; until then the two
  mechanisms must never both be active.
- Talos hostDNS stays enabled, so the dead-socket default resolver would
  still apply to any other `dnsPolicy: Default` pod that is not coreDNS;
  the pod must set its own upstream or `dnsPolicy: ClusterFirst`. coreDNS
  is the only workload that needs a Default-policy resolver today.
- The keeper's `kubectl apply` anchors the Talos-owned ConfigMap with the
  `kubectl.kubernetes.io/last-applied-configuration` annotation; Talos
  re-renders strip it, which is exactly the drift the keeper corrects.

**Open items**

- Install Kyverno ([ADR-014](ADR-014-kyverno.md)), then apply the ClusterPolicy above, delete the
  keeper CronJob, and wire the policies path into its private ArgoCD app.
  The ClusterPolicy content is not committed yet — reproduce from this ADR.
- Migrate the talos catalog to v1.14-style documents (ResolverConfig,
  UnattendedInstallConfig, KubeNetworkConfig, KubePrismConfig,
  KubeProxyConfig) in a dedicated branch. Once complete, disable hostDNS
  via the `ResolverConfig` document (`hostDNS.enabled: false`) and drop
  the keeper/policy — the upgrades then need no post-hoc convergence.
