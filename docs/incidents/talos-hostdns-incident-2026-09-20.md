# Post-mortem: Talos hostDNS DNS outage, 2026-09-20

- **Date**: 2026-09-20
- **Status**: Resolved, fixes applied
- **Component**: Cluster DNS (coreDNS upstream), Talos v1.14 hostDNS default
- **Severity**: Full cluster DNS outage, GitOps loop stopped (all ArgoCD applications `Unknown`)
- **Duration**: One day (Sep 20 upgrade), permanently fixed the same day

## Summary

After the Talos `v1.13.9` → `v1.14.0` / K8s `1.35.8` → `1.37.0` upgrade,
cluster DNS died. coreDNS returned SERVFAIL or empty answers for every
record, internal (`gitea.yourdomain.internal`) and external (`google.com`)
alike. Every ArgoCD application went `Unknown` and the GitOps loop stopped.

Root cause: Talos v1.14 enables `hostDNS` by default. It hands
`dnsPolicy: Default` pods (coreDNS) the nameserver `169.254.116.108`, a
link-local socket with no daemon behind it, so coreDNS had no working upstream.
Talos at or below v1.13 defaulted hostDNS off, so the same pods read
`/etc/resolv.conf` and DNS worked. Interim fix: a `coredns-upstream-keeper`
CronJob re-applies the coreDNS ConfigMap with the working `forward` upstream
every 5 minutes, so any future Talos re-render of the ConfigMap self-heals.
Replaced by a Kyverno ClusterPolicy once Kyverno is installed
([ADR-023](../decisions/ADR-023-coredns-upstream-kyverno.md)).

## Timeline

- **2026-09-20**: Upgrade to Talos `v1.14.0` / K8s `1.37.0`. Cluster DNS
  breaks and flaps all day; ArgoCD applications go `Unknown`, cert-manager
  stalls, the GitOps loop stops.
  - Direct queries from nodes and `busybox` pods against the resolvers always
    succeed. Queries via coreDNS return `NOERROR` with zero answers, or
    `SERVFAIL`.
  - Direct `getent hosts` per node against the resolver succeeds on all four
    nodes, so no source-IP ACL blocks the resolvers.
  - A manual coreDNS ConfigMap patch (`forward . <resolver1> <resolver2>`)
    restores DNS as a stopgap.
  - Machine-config levers tried and rejected, in order: `cluster.hostDNS`
    disabled (key moved to the `ResolverConfig` document in v1.14, decoder
    rejects), `machine.kubelet.resolvConf` pinned (decoder rejects),
    `extraConfig.resolvConf` / `extraArgs["resolv-conf"]` (decode, but
    hostDNS rewrites the kubelet resolver config at boot and wins), and
    `ResolverConfig.hostDNS.enabled: false` on provider `0.12.0-rc.0` (plan
    decodes, apply rejected, see root cause 3).
  - Chosen fix (interim): `coredns-upstream-keeper` CronJob pins the coreDNS
    Corefile upstream every 5 minutes; Kyverno ClusterPolicy later. Provider
    stays on `0.11.0`; no machine config change.

## Root causes

### 1. Talos v1.14 enables hostDNS by default and points `dnsPolicy: Default` pods at a dead socket

v1.14 enables `hostDNS` (`enabled: true`, `forwardKubeDNSToHost: true`) when
the config does not set it. Kubelet fills pod `resolv.conf` with
`169.254.116.108`, and no daemon listens there. coreDNS uses
`dnsPolicy: Default`, so it has no functional upstream. Talos ≤ v1.13
defaulted hostDNS off, so the same pods used `/etc/resolv.conf`.

### 2. The hostDNS config moved to the `ResolverConfig` document in v1.14

"Host DNS configuration has been moved from the v1alpha1 config
`.machine.features.hostDNS` field to the new `hostDNS` section of the
`ResolverConfig` document." The old `cluster.hostDNS` key no longer exists,
and the pinned talos provider (`0.11.0`) predates the document, so no
override lever worked.

### 3. v1.14 rejects re-applying v1alpha1-style configs that carry old keys in parallel with its persisted documents

With provider `0.12.0-rc.0` the `ResolverConfig` patch decodes, but apply
fails. Nodes running v1.14 persist the new-style documents (ResolverConfig,
UnattendedInstallConfig, KubeNetworkConfig, KubePrismConfig,
KubeProxyConfig) and reject any config that still sets the old v1alpha1 keys
(`.machine.install`, `.machine.network.nameservers`,
`.machine.cluster.network`, `.machine.features.kubePrism`,
`.machine.cluster.proxy`, `.machine.kubelet`) with "cannot be used with
... document" conflicts. Disabling hostDNS through the machine config needs
the full v1alpha1 → v1.14 document migration first.

### 4. Misleading secondary symptom: AdGuard rate-limit empty answers

While probing, coreDNS intermittently returned `NOERROR` with zero answers
while direct lookups worked. AdGuard Home rate-limiting per `/24` caused it
during the probe burst, not a cluster fault, and it pulled attention from the
real breakage.

The same upgrade changed a second datapath default, egress SNAT. The cluster
shipped with `enableIPv4Masquerade=false` pinned on the assumption that
"Talos handles NAT". v1.14 broke that assumption and pod → LAN egress broke.
We fixed it by re-enabling BPF masquerade (`fix/cilium-masquerade-lan`).
Verify the datapath (DNS and NAT) after any upgrade, not just DNS.

## Detection

- `kubectl -n argocd get app` → all `Unknown`; cert-manager stalled.
- `nslookup gitea.yourdomain.internal` via coreDNS → `SERVFAIL` / empty,
  while `getent hosts gitea.yourdomain.internal 192.0.2.100` on each node
  returned the record directly.
- `kubectl run busybox ... cat /etc/resolv.conf` with `dnsPolicy: Default` →
  `nameserver 169.254.116.108`.
- Direct query to `169.254.116.108` from that pod → "connection timed out;
  no servers could be reached".
- `talosctl get machineconfig -o yaml` showed `hostDNS: enabled: true`,
  `forwardKubeDNSToHost: true`. The IaC never requests hostDNS.

## Fixes

- Stopgap (live, untracked): coreDNS ConfigMap
  `forward . <resolver1> <resolver2>`. The ConfigMap is Talos-rendered, so
  the manual edit would vanish on the next upgrade.
- Interim: `coredns-upstream-keeper` CronJob
  (`kubernetes/infrastructure/private/coredns-upstream/cronjob.yaml`)
  re-applies the desired coreDNS Corefile (pinned `forward .` upstream)
  every 5 minutes, replacing any Talos re-render.
- Permanent (pending Kyverno install, [ADR-014](../decisions/ADR-014-kyverno.md)): Kyverno `ClusterPolicy`
  (form in [ADR-023](../decisions/ADR-023-coredns-upstream-kyverno.md)) mutating the Talos-rendered coreDNS ConfigMap,
  `background: false`, reacting at admission time once Kyverno is deployed;
  then the keeper CronJob is deleted.
- [ADR-023](../decisions/ADR-023-coredns-upstream-kyverno.md) rewritten as `coredns-upstream-kyverno.md`: decision (interim
  keeper, later Kyverno policy), rejected machine-config levers, follow-ups.
- Upgrade runbook §6 gained a DNS verification block (keeper present, pinned
  upstream, `nslookup` through coreDNS).

Result: cluster DNS resolves through the pinned upstream, and any Talos
re-render of the ConfigMap is replaced within 5 minutes, with no manual
re-apply.

## Lessons learned

- A cluster upgrade can silently change the *semantics* of `dnsPolicy: Default`.
  Verify such a pod's `resolv.conf` after every Talos upgrade.
- The post-upgrade runbook had no DNS check, so we found the outage only
  because ArgoCD applications went `Unknown`.
- A link-local address in `resolv.conf` with nothing behind it is a Talos-side
  default, not a config you own, and hostDNS rewrites kubelet settings at
  boot. Do not try to override it.
- v1alpha1 keys and the new documents cannot coexist in one config, so plan
  the migration before you need a new machine-config lever.
- Per-network resolver rate limits produce phantom `NOERROR` empty answers
  under probe bursts. Recognize it before chasing a source-IP/EDNS ghost.
- OpenTofu does not select provider prereleases from a range constraint. An
  exact `= 0.12.0-rc.0` pin was needed, and the branch still carries the
  range→pin history as evidence.
- Replacing the *whole* coreDNS Corefile is dangerous. The Talos deployment
  probes readiness on `:8181/ready`, which only the `ready` plugin serves. An
  interim keeper that swapped in a Corefile without `ready` made coreDNS run
  but never become Ready. That emptied the `kube-dns` endpoints and took ALL
  cluster DNS out, a worse regression than the fault being fixed. Keep `ready`
  (and any probe-referenced plugin) when replacing the Corefile wholesale.

## Follow-ups

- [ ] Install Kyverno ([ADR-014](../decisions/ADR-014-kyverno.md)), apply the ClusterPolicy from [ADR-023](../decisions/ADR-023-coredns-upstream-kyverno.md), and
  delete the `coredns-upstream-keeper` CronJob.
- [ ] Migrate the talos catalog to v1.14-style documents (ResolverConfig,
  UnattendedInstallConfig, KubeNetworkConfig, KubePrismConfig,
  KubeProxyConfig) on a dedicated branch, then disable hostDNS via
  `ResolverConfig.hostDNS.enabled: false` and drop the keeper/policy.
- [ ] Move the talos provider off `0.11.0` once the `0.12.0` line is stable
  (rc.0 as of 2026-09).
- [ ] AdGuard Home: raise the per-`/24` rate limit, or document probe
  etiquette so debug bursts do not get throttled.
- [ ] Consider a Kyverno `validate` that fails an upgrade if the coreDNS
  ConfigMap ever loses the pinned forward line (`MutateExisting` + validate
  would make drift impossible to miss).
