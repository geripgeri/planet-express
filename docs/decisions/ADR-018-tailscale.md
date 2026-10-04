# ADR-018: Tailscale Free Tier over Self-Hosted Headscale + OCI VPS for Remote Access

## Status

Accepted

## Context

The homelab runs services in daily use: a photo library, media server, home automation, and various self-hosted tools. Remote access required manually connecting a [WireGuard](https://www.wireguard.com) tunnel configured on the [Mikrotik](https://mikrotik.com) router with static keys and explicit peer configuration. The tunnel works, but the friction is real: connect before opening Grafana (see [ADR-011](ADR-011-observability.md)), disconnect afterwards to avoid routing all traffic through the home connection, repeat on every device. Services that are technically accessible become practically ignored when away from home.

The Mikrotik setup is purpose-built for site-to-site links and infrastructure access, not for the "check my photos on my phone without thinking about it" use case.

Self-hosting is the default position for this project. Every other component is self-hosted: Gitea (see [ADR-004](ADR-004-renovate.md)), Authentik (see [ADR-008](ADR-008-authentik.md)), Garage (see [ADR-010](ADR-010-garage.md)), AdGuard (see [ADR-019](ADR-019-adguard-ha-setup.md)), Prometheus/Loki/Grafana (see [ADR-011](ADR-011-observability.md)). The self-hosted option for a VPN coordination layer is [Headscale](https://github.com/juanfont/headscale) on a publicly accessible [Oracle Cloud Infrastructure (OCI) free tier](https://www.oracle.com/cloud/free/) VPS, and the case for it is principled: no external dependency, no third-party visibility into device membership, no exposure to Tailscale's pricing decisions. Those are real arguments. The decision not to use Headscale is not because self-hosting is hard. It is because the specific threat model does not justify the operational cost.

**What [Tailscale](https://tailscale.com) actually controls.** Tailscale runs a coordination server that distributes public keys, assigns IPs in the `100.64.0.0/10` range, and brokers NAT traversal. Once two devices have exchanged keys and established a direct WireGuard tunnel, Tailscale's servers are not in the traffic path. WireGuard private keys are generated on-device and never transmitted to Tailscale. A compromised control plane could redirect connections to an attacker-controlled [Designated Encrypted Relay for Packets (DERP)](https://tailscale.com/kb/1232/derp-servers/) relay, but devices with exchanged public keys reject traffic that does not authenticate. Tailscale sits in the same trust position as a DNS server for WireGuard peers: it knows which devices exist and their public keys, not what they communicate.

**The Headscale + OCI path introduces its own failure modes.** A publicly accessible Headscale VPS needs hardening, patching, monitoring, and consistent attention, and a misconfigured or unpatched public-facing server is a common source of real compromises. OCI free tier instances have a known history of unpredictable availability and arbitrary termination. Any Headscale outage means losing remote access during exactly the situations where it matters most. The realistic comparison is Tailscale's control plane (professionally run, security-audited, with a business model that depends on trust) against a personally managed public server with varying attention, and the OCI VPS is the more likely compromise source.

**The existing stack already accepts comparable trust.** Renovate (see [ADR-004](ADR-004-renovate.md)) has webhook access to git repositories and opens pull requests with code changes. Helm chart registries supply charts applied directly to the cluster. [Talos Image Factory](https://factory.talos.dev) supplies node images. Let's Encrypt (see [ADR-015](ADR-015-disaster-recovery.md)) issues wildcard TLS certificates. Tailscale's control plane visibility is narrower than several of these, so treating it as uniquely unacceptable would apply the threat model inconsistently.

The Mikrotik WireGuard setup stays in place for infrastructure and site-to-site use. This decision adds a purpose-fit access layer alongside it.

## Decision

I decided to use Tailscale free tier for personal device remote access, with the following configuration.

**Subnet router.** A Tailscale subnet router (Proxmox LXC or Kubernetes pod) advertises the home LAN CIDR into the tailnet. Personal devices reach any internal service by IP without routing all traffic through the homelab, and no inbound firewall ports are opened on the Mikrotik router.

**[MagicDNS](https://tailscale.com/kb/1081/magicdns/) with split DNS.** Both AdGuard LXC IPs are registered as restricted nameservers for the internal domain (`*.yourdomain.internal`), which integrates with the AdGuard HA setup from [ADR-019](ADR-019-adguard-ha-setup.md) and avoids a single point of failure for internal DNS resolution.

**ACL policy.** The default allow-all policy is replaced immediately. The owner gets full access. Additional users get HTTP/HTTPS to internal services only, while SSH and the Proxmox management port stay owner-only.

**Authentik OIDC is not integrated.** That requires a paid Tailscale plan. On the free tier, device registration uses Tailscale's own identity providers (Google, GitHub, or email), and identity management for Tailscale and for internal services is treated as a separate concern.

## Consequences

**Positive:**

- Personal devices reach `*.yourdomain.internal` without manual VPN steps or IP address management
- No inbound firewall ports opened, because the subnet router establishes outbound connections only
- MagicDNS resolves correctly from either AdGuard instance, with AdGuard HA from [ADR-019](ADR-019-adguard-ha-setup.md) providing redundancy
- The Mikrotik WireGuard setup keeps serving infrastructure use cases without conflict
- ACL policy keeps SSH and Proxmox management inaccessible to non-owner tailnet members
- The configuration, sanitised ACL template, and the Headscale/Tailscale reasoning are published to the public GitHub and Codeberg mirror

**Negative / accepted costs:**

- External dependency on Tailscale's coordination infrastructure: new connections fail if Tailscale is unavailable, while existing sessions continue
- Tailscale's control plane sees device registration and public keys, but not traffic content
- Authentik is not the identity provider for Tailscale on the free tier. Centralised identity for Tailscale device registration stays out of scope until the user set grows or a paid plan is warranted

**Revisit triggers.** If Tailscale changes pricing materially, is acquired in a way that changes the trust model, or if self-hosting becomes a hard requirement, Headscale on dedicated self-managed infrastructure (not OCI free tier) is the path to revisit.
