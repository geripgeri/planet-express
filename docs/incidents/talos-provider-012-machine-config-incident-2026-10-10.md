# Post-mortem: talos provider 0.12.0 blocked every machine config apply, 2026-10-10

- **Date**: 2026-10-10
- **Status**: Resolved, provider reverted to `0.11.0`
- **Component**: `siderolabs/talos` OpenTofu provider, `talos-cluster` unit
- **Severity**: Cluster reconfiguration blocked. No machine config apply of any kind succeeded, which also blocked every Kubernetes version bump.
- **Duration**: About one hour to root cause, about one hour to finish the upgrade it blocked

## Summary

PR 123 (`chore(deps): update terraform talos to v0.12.0`, opened 2026-09-21) bumped the
OpenTofu provider from `0.11.0` to `0.12.0`. Provider `0.12.x` renders Talos v1.14
configuration *documents* (`UnattendedInstallConfig`, `KubeNetworkConfig`,
`KubePrismConfig`, `KubeProxyConfig`, `KubeFlannelCNIConfig`). The four templates in
`infrastructure/catalogs/public/talos/files/` still patch the legacy v1alpha1 paths.
A submission carrying both styles is invalid, and every node rejected it.

The breakage went unnoticed until 2026-10-10, when a routine Talos patch bump
(`v1.14.1` → `v1.14.2`, PR 150) hit it. Talos `v1.14.2` was reached by upgrading the
nodes out of band; reverting the provider to `0.11.0` restored the apply path.

`ADR-023` had already recorded the hazard in September, when the same document
conflict was hit with provider `0.12.0-rc.0` during the hostDNS incident. That
incident treated `0.12.x` as a blocked upgrade path. Nobody connected that to the
provider bump Renovate had queued.

## Timeline

- **2026-09-21**: PR 123 opens, bumping the provider `0.11.0` → `0.12.0`. All seven CI
  checks pass.
- **After 2026-09-26**: PR 123 merges into `main`. The pin in
  `infrastructure/catalogs/public/talos/main.tf` and the regenerated
  `.terraform.lock.hcl` both move to `0.12.0`. (Still open on 2026-09-26, which is
  the last date the Renovate snapshot covers; the merge commit was not traced.)
- **2026-10-10 14:59**: Applying PR 150 (`terragrunt apply` in the `talos-cluster`
  unit). All four `talos_machine_configuration_apply` resources fail with
  `rpc error: code = InvalidArgument`. Six validation errors on the controller,
  five on each worker. The apply aborts after `null_resource.rolling_upgrade` and
  `null_resource.verify_upgrade` were destroyed, leaving both absent from state.
- **15:00-16:10**: Diagnosis and the out-of-band Talos upgrade to `v1.14.2`. All four
  nodes reach `v1.14.2`; state still carries the pending machine config delta.
- **16:19**: Provider reverted to `0.11.0`, lockfile regenerated, `terragrunt apply`
  completes: `1 added, 4 changed, 0 destroyed`. `verify_upgrade` confirms
  `Talos v1.14.2 OK` on all four nodes and kubelet `v1.37.0`.

## Root cause

Provider `0.12.x` renders the Talos v1.14 document set. The catalog still patches
v1alpha1 keys, so the submitted config carried both and every node rejected it:

```
UnattendedInstallConfig config is incompatible with v1alpha1 config (.machine.install)
.machine.network.nameservers is already set in v1alpha1 config
cluster network config is already set in the v1alpha1 config (.machine.cluster.network)
KubePrism config in v1alpha1 config (.machine.features.kubePrism) can't be used with KubePrismConfig document
cluster proxy config in v1alpha1 config (.machine.cluster.proxy) can't be used with KubeProxyConfig document
cluster network config in v1alpha1 config (.machine.cluster.network) can't be used with KubeFlannelCNIConfig document
```

Every key in that list traces to a template in the catalog:

| Rejected key                   | Template                              |
| ------------------------------ | ------------------------------------- |
| `.machine.install`             | `files/init_install_controller.tfmpl` |
| `.machine.features.kubePrism`  | `files/init_install_controller.tfmpl` |
| `.machine.cluster.network`     | `files/init_install_controller.tfmpl` |
| `.machine.cluster.proxy`       | `files/init_install_controller.tfmpl` |
| `.machine.network.nameservers` | `files/vlan20_interface.tfmpl`        |
| `.machine.kubelet`             | `files/init_install_worker.tfmpl`     |

`.machine.kubelet` appears only in the worker error and is absent from the
controller error. Only `init_install_worker.tfmpl` sets it, so the error list maps
one-to-one onto the templates.

The nodes were never involved. `talosctl get <document> v1alpha1` returns no
instances on any node; the documents arrived in the submission, not from node state.

### Evidence

The rendered config is a sensitive provider attribute, so `tofu console` redacts it
and the document set was never read directly. The conclusion rests on three
indirect signals:

1. **Hashes move with the provider version.** Identical inputs, provider `0.12.0`
   versus `0.11.0`:

   | Node       | Provider `0.12.0` | Provider `0.11.0` |
   | ---------- | ----------------- | ----------------- |
   | controller | `43d3ce7a…`       | `e788346d…`       |
   | worker-01  | `a7314195…`       | `182201c6…`       |
   | worker-02  | `3d92b03e…`       | `b1454a35…`       |
   | worker-03  | `04f9c1ce…`       | `12a44619…`       |

2. **The nodes hold no documents**, so the conflicting documents were in the
   submission.

3. **Reverting the provider restored the apply path completely**, with all four
   `talos_machine_configuration_apply` resources succeeding.

## Detection

CI could not see this. PR 123 was green on all seven checks, including
`Tofu Plan / plan` and `Tofu Static / static`. Neither applies a configuration to a
node, and document validity is only checked node-side at apply time.

The failure surfaced only when someone ran `terragrunt apply` against the live
cluster.

Three signals would have cut this short:

- **`tofu init` printing a provider version that differs from the committed
  lockfile.** During diagnosis, `tofu init` reported `siderolabs/talos v0.12.0`
  while the committed lockfile in the repo read `0.11.0`. That mismatch is the
  whole bug, printed at init.
- **Comparing planned hashes across a single-variable change.** Changing nothing
  but the provider version moved all four `machine_configuration_hash` values
  (`43d3ce7a…` → `e788346d…` on the controller). The provider, not the cluster,
  drives what gets rendered.
- **Reverting one variable at a time.** `v1.14.2` stayed pinned through the whole
  diagnosis. The apply succeeded once the provider moved, which placed the fault
  without ever testing the version bump separately.

## How the diagnosis went wrong

Recorded because each wrong turn cost time and each would mislead the next
investigation.

- **We blamed the Talos version bump first.** The hypothesis was that `v1.14.2`
  tightened validation. Nothing in the error named a version. Reverting only the
  provider, with `v1.14.2` still pinned, made all four applies succeed, which put
  the fault on the provider. The version bump was never tested on its own.
- **We assumed the nodes had adopted the documents.** `ADR-023` says v1.14 nodes
  persist them. The nodes did not; the submission did.
- **We trusted a stale repository view.** The investigation ran against a checkout
  where the provider was still pinned to `0.11.0`, which is why PR 123 looked like
  an open, unmerged PR until its blob hash showed up in the diff of a file being
  edited against `main`.
- **`kubectl drain` spent an hour in a retry loop.** Every Longhorn
  instance-manager PDB is `minAvailable: 1` with exactly one pod behind it, so
  `ALLOWED DISRUPTIONS` is `0` and evictions are refused forever. `talosctl upgrade`'s built-in drain hits its client-side rate-limiter deadline and returns
  non-zero. See the drain step now in the upgrade runbook.

## Fixes

- **Reverted the provider to `0.11.0`** in
  `infrastructure/catalogs/public/talos/main.tf` and regenerated
  `infrastructure/units/public/talos/talos-cluster/.terraform.lock.hcl`. All four
  machine config applies succeed. The `0.11.0` pin is load-bearing and
  [ADR-023](../decisions/ADR-023-coredns-upstream-kyverno.md) depends on it: hostDNS
  is neutralised by the `coredns-upstream-keeper` CronJob, so the `ResolverConfig`
  document that `0.12.x` unlocks is not needed.
- **Renovate guard for the provider.** The `custom.regex` guard covered the Talos
  and Kubernetes *version* pins. The provider arrived through the `terraform`
  manager and matched nothing, so it inherited the global minor/patch automerge.
  `renovate.json5` now carries a separate rule for it.
- **Drain step in the upgrade runbook**, with the PDB relaxation the Longhorn
  layout requires.

## Lessons learned

- A provider bump can invalidate a config the provider itself generated. Pin
  versions and the provider together; they are not independent axes.
- `ADR-023` already described this exact error. The gap was that the ADR read as a
  note about a rejected experiment, not as a standing constraint on the provider
  pin. Constraints that block automated updates belong in `renovate.json5`, where
  Renovate reads them.
- CI that only plans and lints cannot see configuration validity. Any change that
  is only rejected at apply time needs a live apply to verify, which means the
  change must be gated by something other than CI green.
- Change one input at a time and read the planned hashes. All four
  `machine_configuration_hash` values moved when only the provider version
  changed, which located the fault in one step.
- The Talos upgrade itself survived a blocked module. `talosctl upgrade` writes the
  installer image and does not depend on the machine config, so a broken apply path
  blocks reconfiguration without blocking the version bump. That separation is
  what made recovery possible.

## Follow-ups

- [ ] Fix the false success in `null_resource.rolling_upgrade`
  (`infrastructure/catalogs/public/talos/main.tf`). After a failed upgrade it
  logs `Worker <ip> back up after upgrade` because the wait loop polls
  reachability rather than the reported version. A node that never rebooted
  satisfied the probe. Compare the `Tag:` field the resource already parses
  during the pre-upgrade check.
- [ ] Decide whether `0.12.x` is wanted at all. If the intent is to adopt the v1.14
  documents, that is the catalog migration already tracked in
  [ADR-023](../decisions/ADR-023-coredns-upstream-kyverno.md) open items, and
  the four templates move to the document set in the same change as the
  provider bump. If the intent is to stay on `0.11.0`, close PR 123 and let
  Renovate ignore the dependency.
- [ ] Consider guarding every `terraform`-manager update rather than only this
  provider. No other provider in the catalog currently manages cluster-critical
  configuration, but the CI gap applies to all of them.
