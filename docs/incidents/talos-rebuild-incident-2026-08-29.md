# Post-mortem: Talos rebuild incident, 2026-08-29

- **Date**: 2026-08-29
- **Status**: Resolved, fixes applied
- **Component**: terraform module for the Talos cluster, Proxmox ISO handling
- **Severity**: Bootstrap hang, no new cluster. Existing workloads kept running on old VMs.
- **Duration**: Rebuild blocked for two days, required manual bootstrap

## Summary

A fresh `terragrunt stack run apply` for Talos `v1.13.9` and Kubernetes `v1.35.8` did not bootstrap. The apply hung for 2h49m waiting for the controller, then needed a manual `talosctl bootstrap`. The following apply failed on `rolling_upgrade` with `connection refused` on a worker, and nodes stayed `NotReady`.

No data was lost. The fix made bootstrap and upgrade idempotent and one-shot.

## Timeline

- 2026-08-28: Pin Talos to `v1.13.9`, K8s to `v1.35.8`, Proxmox provider to `3.0.2-rc07`. Add versioned ISO via Ansible.
- 2026-08-30: Renovate bumps the Proxmox provider `rc08` then `rc09`; both fail fresh VM create with "VM already running" (double-start, Telmate#1542). Fixed by the talos branch pin to `3.0.2-rc10`.
- 2026-08-29 14:28: `stack run apply` creates 4 VMs. `ip_addresses` output is empty (`""`) for all VMs. Talos `qemu-guest-agent` is no longer in the base image in 1.13.
- 2026-08-29 19:13: Controller boots 23m11s. `etcd` waits for bootstrap. `talosctl version` shows all 4 nodes on `v1.13.9` even in maintenance mode.
- 2026-08-29 20:59: `cluster_bootstrap` still creating after 2h49m, waiting for `192.0.2.31`. `etcd status` hangs forever in maintenance mode, so the check never returned.
- 2026-08-29 21:00: Manual `talosctl -n 192.0.2.30 bootstrap` makes etcd healthy. Check shows `talosctl` client was `v1.13.8` while servers were `v1.13.9`.
- 2026-08-29 23:50: With fixes, bootstrap completes in 1m56s. `cluster_health` then fails on `192.0.2.31` and `rolling_upgrade` fails with `connection refused`. `kubectl get nodes` shows 4 nodes on `v1.35.8` but `NotReady`.

## Root causes

### 1. Outdated talosctl client

The host had `v1.13.8` while the cluster was `v1.13.9`. No check compared them, so the mismatch was not reported.

### 2. etcd status hangs before bootstrap

`talosctl -n 192.0.2.30 etcd status` hangs forever in maintenance mode. The `if etcd status` check in `cluster_bootstrap` never finished, so `bootstrap` never ran.

`talosctl version` works in maintenance mode and shows all nodes. That plus the hang signals not bootstrapped.

Bootstrap only works once. A second call fails, so the check must be correct.

### 3. Bootstrap waited for all nodes

`cluster_bootstrap` waited for `controller + 3 workers` before bootstrap. Each wait was 90\*10s = 15m. With controller boot at 23m, the wait timed out. Workers should wait via `cluster_health` after bootstrap.

### 4. Guest agent and IP output empty

`proxmox_vm_qemu` output `default_ipv4_address` needs `qemu-guest-agent`. The plain `metal-amd64.iso` in 1.13 no longer includes it. Factory ISO `ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515` does. With empty `ip_addresses`, a one-shot stack would have no IPs for `talos-cluster`. The first fix used direct `cidrhost`, which works but couples the two units.

### 5. Health and upgrade did not retry

`cluster_health` ran once without retry and marked healthy even when `192.0.2.31` refused connection. `rolling_upgrade` tried to upgrade without waiting for the node to be reachable and without checking current version.

### 6. Verify required Ready

`verify_upgrade` required `Ready` and kubelet version. Talos has `cni: none` and proxy disabled, so nodes stay `NotReady` until Cilium is deployed. The check would always fail on a fresh cluster.

### 7. Proxmox provider double-start on fresh create

The telmate `proxmox` provider at `rc08`/`rc09` issues a second start on VMs it has just created, failing fresh creates with "VM already running" (Telmate/terraform-provider-proxmox#1542). This made provisioning non-idempotent: the first apply half-creates a VM, and a re-run cannot start it. The incident pinned `rc07`, then Renovate drifted it to `rc09`; neither documented why the provider pin mattered, so the regression went unnoticed until `stack run apply` was exercised.

## Detection

- `ip_addresses = ""` for all VMs after `talos-vms` apply.
- `Still creating [2h49m]` and `attempt 6/90` with `Client Tag v1.13.8`.
- Direct `talosctl version` showing 4 servers on `v1.13.9` while `etcd status` hangs.
- `qm agent 500 ping` returning 0 on `linuxnocloud` and `metal v1.12.2` ISOs, but not on plain `metal v1.13.9` ISO. Factory ISO with agent works.

## Fixes

- Compare `talosctl version --client` and server `Tag`. Fail fast if they differ.
- Wrap `etcd status` with `timeout 10`. Hang is treated as not bootstrapped.
- Change `cluster_bootstrap` to wait for controller only, keep `90*10s` timeout per request.
- Make `proxmox-vm` accept `static_ip_addresses`. `talos-vms` builds `192.0.2.30-33` via `cidrhost(vlan-10.subnet, vmid-470)` and returns them. `talos-cluster` now uses `dependency.talos_vms.outputs.ip_addresses`.
- Add `metal-amd64.iso` download as `talos-<version>-nocloud-amd64.iso` via Ansible single source `proxmox_base_talos_iso_version`. Keep 5 most recent ISOs with prune task using `pipefail`.
- Make `cluster_health` retry `get machinestatus` per node.
- Make `rolling_upgrade` wait for each node, skip if already on `v1.13.9`, wait after reboot. Controller last.
- Change `verify_upgrade` to check only kubelet version, not `Ready`.
- Pin the Proxmox provider to `3.0.2-rc10`, which fixes the "VM already running" double-start on fresh create (Telmate/terraform-provider-proxmox#1542). The pin carries a `# rc10 fixed...` comment in `infrastructure/catalogs/public/proxmox-vm/main.tf` so Renovate cannot silently drift it past the broken `rc08`/`rc09`.

Result: `stack run apply` now bootstraps in 1m56s, `etcd` healthy, all 4 Talos nodes on `v1.13.9`.

## Lessons learned

- Pin the CLI to the cluster version and check it in automation.
- Never run a check that can hang without `timeout`.
- Bootstrap needs controller only. Workers join after.
- Make health and upgrade idempotent and retrying. Check current version before upgrading.
- Do not require `Ready` when CNI is `none`. Check version only.
- Do not rely on guest agent for IPs on Talos. Pass static reservations through outputs.
- Keep versioned ISOs and prune old ones.
- Factory ISO contains the agent. Plain `metal` ISO does not in 1.13. Test both.
- A provider pin is only a fix if the reason is stated in code. The `rc08`/`rc09` regression rode Renovate untested because the `rc07` pin had no comment; a version bump that lacks a `# why` must be treated as suspect until a fresh `stack run apply` passes.

## Follow-ups

- [ ] Use `talos_image_factory_urls` `urls.iso` for the factory ISO directly when the stack can order ISO download before VM create. Today Ansible downloads plain `metal` and the agent arrives via `rolling_upgrade`.
- [ ] Ensure `qemu-guest-agent` extension stays in both schematics. Add `amdgpu` and `amd-ucode` for `Ryzen 8600G` when Jellyfin needs iGPU.
- [ ] Document `qm agent ping` and `talosctl version` vs `etcd status` checks in `docs/runbooks/talos-k8s-upgrade.md`.
- [ ] Add a small docker e2e with `talosctl cluster create docker` to test bootstrap hang handling without Proxmox.

## Follow-up: Cilium operator crash-loop and Longhorn UI outage (2026-09-05)

- **Date**: 2026-09-05
- **Status**: Longhorn UI reachable; operator crash-loop under investigation
- **Component**: Cilium (agent stale configmap mount, operator CrashLoopBackOff)
- **Severity**: LB data path (Longhorn UI) unreachable; operator restarts every ~9 min since install
- **Duration**: since cluster install (08-30); UI outage resolved 09-05

### Symptom

Longhorn UI at `198.51.100.10` unreachable with "No route to host". The Gateway `kube-system/cilium-gateway-shared-gateway` is bound to `.10`, `ipMode: VIP`, but nothing owns the IP on the L2 segment.

### Timeline

- 08-30: Cluster installed from this rebuild. `cilium-operator` crash-loops from install (852 restarts by 09-05 23:00, ~every 9 min).
- 09-04: Control plane 100 % CPU for an hour, then unhealthy until node reboot. This is a separate event; the operator loop predates and persists after it.
- 09-05 22:00: `kubectl rollout restart ds/cilium` forces fresh configmap mounts.
- 09-05 22:51: Longhorn UI reachable.

### Root causes

#### 1. Agents ran a stale configmap mount

The cluster `cilium-config` ConfigMap held the correct L2 values (`enable-l2-announcements: true`, `devices: ens18 ens19`, ...) from the initial apply, but the running agents (up 6d8h) kept an old pod-template mount. kubelet never resynced because the apiserver was flaky (TLS handshake timeouts on the undersized control plane). The L2 responder BPF map (`cilium_l2_responder_v4`) existed but was empty (0 elements), so nothing answered ARP for `.10`. Restarting the DaemonSet repopulated the mounts (`enable-l2-announcements: true` in-pod) and armed the responder.

#### 2. Operator restart loop: apiserver HTTP/2 stalls on the healthz check

The operator's healthz endpoint (`127.0.0.1:9234`) stops answering shortly after each start. Kubelet events: `Liveness probe failed: Get "http://127.0.0.1:9234/healthz": context deadline exceeded`, then `Container failed liveness probe, will be restarted`. `lastState`: `exitCode 1`, `reason Error` — not `OOMKilled`. Node `talos-j1p-g4i` shows no Memory/Disk/PID pressure. The CPU hour was 24 h+ before and unrelated to this cadence.

SIGQUIT goroutine dumps of a wedged operator (via `kubectl debug` + busybox, `kill -QUIT 1`) show every healthz handler goroutine blocked in the same path:

```
(*healthHandler).checkStatus  operator/api/health.go:110
  → (*DiscoveryClient).ServerVersion()                 # HTTP/2 GET to kube-apiserver
  → http2.(*ClientConn).roundTrip transport.go:1400    # select, minutes, never returns
```

The healthz check makes a kube-apiserver discovery call over a **long-lived HTTP/2 connection** to `192.0.2.30:6443` (`k8sServiceHost`). The connection is open but silently dead — no response and no reset — so the `select` blocks forever, the liveness probe times out, and kubelet SIGTERMs the operator. Fresh `kubectl` connections succeed because they open new sockets; the operator reuses one stale multiplexed stream and hangs. Same flaky-apiserver root cause as the stale agent configmap, cycling since install.

The Gateway-API panic theory (upstream [cilium/cilium#41939](https://github.com/cilium/cilium/issues/41939), a `Selector`/no-selector listener nil-deref) is **ruled out**: no panic in the dump, no panic in logs, clean controller startup, every gateway object reconciled (`GatewayClass ACCEPTED True`, `shared-gateway` `.10` `PROGRAMMED True`, HTTPRoute `longhorn` 5d2h).

### Fix applied

- `kubectl rollout restart ds/cilium` (temporary; IaC fixes are committed on `unified`).

### Open items

- [ ] The operator's healthz deadlocks on a stale HTTP/2 stream to the apiserver; confirm the restart loop disappears after the 4 vCPU / 4 GB control-plane bump (proxmox-vm `cores`/`memory` prod override) is applied.
- [ ] The stale-mount failure mode needs a permanent guard; the configmap-resync deadlock came from the flaky apiserver on the undersized control plane. The 4 vCPU / 4 GB control-plane bump (proxmox-vm `cores`/`memory` prod override) addresses the pressure.
