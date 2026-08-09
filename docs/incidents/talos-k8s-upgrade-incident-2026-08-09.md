# Post-mortem: Talos upgrade incident, 2026-08-09

- **Date**: 2026-08-09
- **Status**: Resolved, fixes applied
- **Component**: terraform module for the Talos cluster
- **Severity**: Management-plane outage. Workloads kept running.
- **Duration**: Operator lockout for several hours, upgrade delayed by months

## Summary

We tried to upgrade Talos from v1.12.4 to v1.13.8. The `terragrunt apply`
regenerated the machine secrets (all certificate authorities, the service
account signing key, and the operator client configuration). Every
talosconfig stopped working right after the apply wrote the new secrets to
state. The nodes rejected all clients with `x509: certificate signed by unknown authority`.

After we recovered from that, the second apply failed to upgrade three of
the four nodes, but did not report the failure. The upgrades continue in the
background after the command returns, and they died silently.

No data was lost. The nodes never received a config they would reject.
Services kept running. Only our access to the cluster was lost.

## Timeline

- 2026-03: Cluster bootstrapped (Talos v1.12.4, Kubernetes v1.35.0).
- 2026-08-09 (daytime): Phase-1 apply started (version bump to v1.13.8).
  The apply regenerated the machine secrets and wrote the new certificate
  authorities to state.
- 2026-08-09: Every talosctl and kubectl call failed with x509 errors.
  Recovery started.
- 2026-08-09: We restored the original secrets into the state file, using a
  dated talosconfig from March and the machine config of the controller.
- 2026-08-09: Second apply: configs applied, upgrades issued without
  waiting. One worker lost its connection during the upgrade, two other
  nodes failed in the background. The plan after that said "No changes".
- 2026-08-09: Manual sequential upgrade of all nodes (workers first,
  controller last). All nodes reached v1.13.8 and Ready.
- 2026-08-09: Fixes committed (below). Plan clean.

## Root causes

### 1. Machine secrets depended on the current cluster version

The module set `talos_machine_secrets.talos_version` to the version we were
upgrading to (`var.talos_cluster_details.version`). The provider treats a
version change as "generate fresh secrets". So every upgrade created new
certificate authorities and new client key material, while the nodes kept
the originals.

This is the behavior of provider v0.11.0 (upstream issue
siderolabs/terraform-provider-talos#352). The fix exists only on the 0.12.0
line, which is still in alpha (no stable 0.12.x release).

The rotation cannot be undone without the original certificate
authorities. That is why we were locked out.

Contributing factors: no test cluster, no backup routine for the secrets,
and drift between state and cluster was invisible until the next apply.

### 2. Upgrades ran without waiting or verification

The upgrade steps used `talosctl upgrade --wait=false`. The command returns
as soon as the node accepts the upgrade, while the install and reboot
continue in the background. Four background upgrades ran at the same time on
one host and competed for resources (disk, image downloads, reboot window).
Three of them failed silently. Terraform reported success because nothing
waited or checked afterwards.

## Detection

- x509 errors on every `talosctl` or `kubectl` call. A clear signal, but
  only after the damage was done.
- Version drift: `talosctl version` reported v1.12.4 on three of four
  nodes, hours after a green apply and a plan that said "No changes".

## Recovery (summary)

Full procedure: `docs/runbooks/talos-k8s-upgrade.md` section 7.

1. Dated talosconfig copies in `~/.talos/` from March still worked. The
   cluster still trusted the original certificate authority.
2. We dumped the controller machine config (`talosctl get machineconfig`).
   It contains the original `machine.ca` certificate and key.
3. `scripts/restore_machine_secrets.py` restored the `machine_secrets` and
   `client_configuration` in the state file from those two files. It writes
   a backup copy first.
4. Without the dated talosconfigs we would have: attached the STATE
   partition of a node (qm disk attach or vzdump), read `machine.ca` from
   the XFS config, and created a client certificate by hand. Documented in
   section 7.

## Fixes

- Pin machine secrets to the bootstrap version: new `machine_secrets_version`
  variable (for example v1.12.4). It separates the secrets from the current
  cluster version. Never change it.
- Wait for each upgrade: removed `--wait=false`. The apply now blocks until
  the node reboots and reports the new version. Failed upgrades fail the
  apply.
- Verify after upgrade: the final `verify_upgrade` step checks every node's
  Talos and Kubernetes version and the kubelet Ready state. A stale node
  fails the apply.
- Runbook updates: section 1 backups (state, talosconfig, qm snapshot and
  vzdump), section 5b upgrade behavior, section 7 full recovery steps.

## Lessons learned

- Cluster root credentials exist in two places: the state file and the node
  configs. Regenerating them in one place silently breaks the other.
  Version-dependent secrets must be pinned.
- A green apply says the apply finished, not that the cluster is correct.
  Async remote operations inside the apply need a verification step.
- The dated talosconfig copies in `~/.talos` and the state backup saved us.
  Without them we would have rebuilt the cluster.
- Backups before an upgrade are cheap. A `qm snapshot` per VM takes minutes
  and would have prevented this incident.

## Follow-ups

- [ ] Watch siderolabs/terraform-provider-talos for the stable 0.12.0
  release (the fix for #352 is only in the alpha line so far). When it
  lands, upgrade the pinned provider and re-check if
  `machine_secrets_version` can be relaxed.
- [ ] When the pin is first applied to an existing state: check that
  `terragrunt plan` shows no change for `talos_machine_secrets`. A state
  restored from a rotated attempt still carries the rotated version value.
  Align it with the pinned version before applying. Never apply a plan that
  regenerates secrets.
- [ ] Automate the backups from section 1 (scheduled state copy, reminder
  to rotate the talosconfig copies) instead of relying on habit.
- [ ] `docs/runbooks/cluster-rebuild.md` is still missing (referenced from
  the runbook).
