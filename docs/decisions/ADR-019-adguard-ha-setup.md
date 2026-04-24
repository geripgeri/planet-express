# ADR-019: Dual AdGuard Home LXC with adguardhome-sync for DNS Resilience

## Status

Active

## Context

DNS is a silent foundational dependency. When it fails, the symptom isn't an obvious error but timeout cascades, failed certificate renewals, and broken internal service URLs surfacing hours later. This homelab runs split-horizon DNS: `*.yourdomain.internal` resolves to Cilium (see [ADR-005](ADR-005-cilium-gateway-api.md)) Gateway IPs internally, so a DNS outage breaks every internal URL even for devices on the local LAN.

[AdGuard Home](https://adguard.com/en/adguard-home/overview.html) runs as a Proxmox (see [ADR-000](ADR-000-project-goals.md)) LXC and handles upstream resolution, split-horizon rewrites, and ad/tracker filtering. Its configuration is managed declaratively via the OpenTofu (see [ADR-002](ADR-002-opentofu-terragrunt.md)) AdGuard provider.

The most common failure mode is not hardware: it's me (the operator) patching the LXC, restarting AdGuard after a config change, or accidentally stopping the container. A single instance means any of these creates a full DNS blackout. AdGuard Home has no native high-availability (HA) mode.

The alternatives considered:

- **[keepalived](https://keepalived.org)/VRRP (Virtual Router Redundancy Protocol)**: adds meaningful complexity (multicast, priority tuning, preemption) for minimal gain when both instances run on the same physical host. If the host is up and networking works, both LXCs are reachable directly. If the host is down, VRRP can't help anyway.
- **CoreDNS (see [ADR-015](ADR-015-disaster-recovery.md)) inside Kubernetes**: a dependency inversion. The cluster needs DNS to start and resolve names during reconciliation; putting the resolver inside the cluster creates a circular failure risk. DNS must sit outside Kubernetes.
- **[Pi-hole](https://pi-hole.net)**: architecturally equivalent, but AdGuard Home is already deployed with working OpenTofu IaC. No reason to migrate.

## Decision

I run two AdGuard Home LXCs on the Proxmox host: `adguard-primary` and `adguard-replica`, each with its own IP.

[`bakito/adguardhome-sync`](https://github.com/bakito/adguardhome-sync) runs as a cron process on the primary and pushes the full AdGuard config (DNS rewrites, filter lists, client configs, custom rules) to the replica via the AdGuard API every five minutes. Credentials are stored as SOPS (see [ADR-009](ADR-009-sops.md))-encrypted secrets.

```yaml
# adguardhome-sync.yaml on primary LXC
cron: "*/5 * * * *"
runOnStart: true
continueOnError: true
origin:
  url: http://127.0.0.1:3000
  username: admin
  password: <SOPS-encrypted>
replica:
  url: http://<adguard-replica-lxc-ip>:3000
  username: admin
  password: <SOPS-encrypted>
```

The MikroTik DHCP server lists both IPs as DNS resolvers. Clients use the primary by default and fall back to the replica automatically if the primary doesn't respond. No Virtual IP (VIP), no keepalived.

All configuration changes go through OpenTofu targeting the primary only. The sync process propagates them to the replica within the next five-minute window. The replica is read-only operationally and never a source of truth. Both IPs are also registered in Tailscale (see [ADR-018](ADR-018-tailscale.md)) [MagicDNS](https://tailscale.com/kb/1081/magicdns/) scoped to `yourdomain.internal`, so the failover extends to Tailscale-connected devices as well.

## Consequences

**Eliminated**: the entire class of process and container-level outages. Patching the primary LXC, restarting AdGuard, a crash loop, or accidentally stopping the container no longer causes a DNS blackout for LAN clients.

**Not eliminated**: host-level failure. Both LXCs run on the same Proxmox host. If the host goes down, both resolvers go with it. This is accepted. On a single-host homelab, a host failure is a full-stack outage regardless; DNS being unavailable is not the meaningful additional problem in that scenario.

**Config propagation lag**: changes applied to the primary take up to five minutes to reach the replica. In practice this doesn't matter; DNS changes are rare and deliberate.

**Split-horizon correctness is covered**: adguardhome-sync includes DNS rewrites in its sync scope. Both instances resolve `*.yourdomain.internal` to the Cilium Gateway IP identically. A replica that handles upstream DNS but returns wrong answers for internal names would be worse than no replica at all.

**Operational model**: one canonical state (OpenTofu), one authoritative instance (primary), one passive follower (replica). Debugging always starts from the OpenTofu unit under `infrastructure/units/public/adguard/`. The replica's web UI serves as a passive canary: visible config drift without explanation means the sync process has failed silently.

**Resource cost**: one additional LXC with its own IP and DHCP reservation, managed under `proxmox/lxc/adguard-replica/`. Minimal on a host running well under its CPU and RAM ceiling.
