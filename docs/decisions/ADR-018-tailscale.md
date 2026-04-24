# ADR-018: Tailscale Free Tier over Self-Hosted Headscale + OCI VPS for Remote Access

## Status

Accepted

## Context

The homelab runs services in daily use: a photo library, media server, home automation, and various self-hosted tools. Remote access required manually connecting a [WireGuard](https://www.wireguard.com) tunnel configured on the [Mikrotik](https://mikrotik.com) router with static keys and explicit peer configuration. The tunnel works, but the friction is real: connecting before opening Grafana (see [ADR-011](ADR-011-observability.md)), disconnecting afterward to avoid routing all traffic through the home connection, repeating this on every device. Services that are technically accessible become practically ignored when away from home.

The Mikrotik WireGuard setup is purpose-built for site-to-site links and infrastructure access. It is not the right tool for the "check my photos on my phone without thinking about it" use case.

Self-hosting is the default position for this project. Every other component is self-hosted: Gitea (see [ADR-004](ADR-004-renovate.md)), Authentik (see [ADR-008](ADR-008-authentik.md)), Garage (see [ADR-010](ADR-010-garage.md)), AdGuard (see [ADR-019](ADR-019-adguard-ha-setup.md)), Prometheus/Loki/Grafana (see [ADR-011](ADR-011-observability.md)). For a VPN coordination layer, the self-hosted option is [Headscale](https://github.com/juanfont/headscale), running on a publicly accessible [Oracle Cloud Infrastructure (OCI) free tier](https://www.oracle.com/cloud/free/) VPS. The case is principled: no external dependency, no third-party visibility into device membership, no exposure to Tailscale's pricing decisions. These are real arguments. The decision not to use Headscale is not because self-hosting is hard; it is because the specific threat model does not justify the operational cost.

**What [Tailscale](https://tailscale.com) actually controls.** Tailscale operates a coordination server that distributes public keys, assigns IPs in the `100.64.0.0/10` range, and brokers NAT traversal. Once two devices have exchanged keys and established a direct WireGuard tunnel, Tailscale's servers are not in the traffic path. WireGuard private keys are generated on-device and never transmitted to Tailscale. A compromised control plane could redirect connections to an attacker-controlled [Designated Encrypted Relay for Packets (DERP)](https://tailscale.com/kb/1232/derp-servers/) relay, but devices with exchanged public keys would reject traffic that does not authenticate. Tailscale occupies the same trust position as a DNS server for WireGuard peers: it knows which devices exist and their public keys, not what they communicate.

**The Headscale + OCI path introduces its own failure modes.** A publicly accessible Headscale VPS requires hardening, patching, monitoring, and consistent attention. A misconfigured or unpatched public-facing server is a common and consistent source of real compromises. OCI free tier instances have a known history of unpredictable availability and arbitrary termination. Any Headscale outage means losing remote access during exactly the situations where it matters most. The realistic comparison is Tailscale's control plane (professionally run, security-audited, with a business model that depends on trust) against a personally managed public server with varying attention. The OCI VPS is the more likely compromise source.

**The existing stack already accepts comparable trust.** Renovate (see [ADR-004](ADR-004-renovate.md)) has webhook access to git repositories and opens pull requests with code changes. Helm chart registries supply charts applied directly to the cluster. [Talos Image Factory](https://factory.talos.dev) supplies node images. Let's Encrypt (see [ADR-015](ADR-015-disaster-recovery.md)) issues wildcard TLS certificates. Tailscale's control plane visibility is narrower than several of these. Treating it as uniquely unacceptable would be an inconsistent application of the threat model.

The Mikrotik WireGuard setup is explicitly preserved for infrastructure and site-to-site use. This decision adds a purpose-fit access layer alongside it.

## Decision

I decided to use Tailscale free tier for personal device remote access, with the following configuration.

**Subnet router.** A Tailscale subnet router (Proxmox LXC or Kubernetes pod) advertises the home LAN CIDR into the tailnet. Personal devices reach any internal service by IP without routing all traffic through the homelab. No inbound firewall ports are opened on the Mikrotik router.

**[MagicDNS](https://tailscale.com/kb/1081/magicdns/) + split DNS.** Both AdGuard LXC IPs are registered as restricted nameservers for the internal domain (`*.yourdomain.internal`), integrating with the AdGuard HA setup from [ADR-019](ADR-019-adguard-ha-setup.md) and avoiding a single point of failure for internal DNS resolution.

**ACL policy.** The default allow-all policy is replaced immediately. The owner gets full access. Additional users get HTTP/HTTPS to internal services only; SSH and the Proxmox management port are owner-only.

**Authentik OIDC is not integrated.** That requires a paid Tailscale plan. On the free tier, device registration uses Tailscale's own identity providers (Google, GitHub, or email). Identity management for Tailscale and for internal services are treated as separate concerns.

## Consequences

**Positive:**

- Personal devices have frictionless access to `*.yourdomain.internal` without manual VPN steps or IP address management
- No inbound firewall ports opened; the subnet router establishes outbound connections only
- MagicDNS resolves correctly from either AdGuard instance, with AdGuard HA from [ADR-019](ADR-019-adguard-ha-setup.md) providing redundancy
- The Mikrotik WireGuard setup continues to serve infrastructure use cases without conflict
- ACL policy keeps SSH and Proxmox management inaccessible to non-owner tailnet members
- The configuration, sanitised ACL template, and the Headscale/Tailscale reasoning are published to the public GitHub and Codeberg mirror

**Negative / accepted costs:**

- External dependency on Tailscale's coordination infrastructure. New connections cannot be established if Tailscale is unavailable; existing sessions continue.
- Tailscale's control plane has visibility into device registration and public keys. Traffic content is not visible.
- Authentik is not the identity provider for Tailscale on the free tier. Centralised identity for Tailscale device registration is out of scope until the user set grows or a paid plan is warranted.

**Revisit triggers.** If Tailscale changes pricing materially, is acquired in a way that changes the trust model, or if self-hosting becomes a hard requirement, Headscale on dedicated self-managed infrastructure (not OCI free tier) is the path to revisit.
