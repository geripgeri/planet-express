# ADR-008: Authentik as the Identity Provider

## Status

Active

## Context

A homelab running a dozen self-hosted services has a credential management problem. Each app handles its own authentication: separate passwords, inconsistent MFA coverage, and no central place to revoke access. Password reuse across services is a real risk, and every new app means another credential to manage.

The fix is a centralized identity provider. Every app delegates authentication to it, revoking access happens once, and MFA is enforced at the IdP level instead of left to each app.

**Why not a managed IdP?** [Cloudflare Access](https://www.cloudflare.com/zero-trust/products/access/), [Okta](https://www.okta.com/), and [Auth0](https://auth0.com/) solve the problem without the operational burden, but self-hosting is a project goal, see [ADR-000](ADR-000-project-goals.md) for the principles behind it. A managed IdP puts an external dependency in the auth path of every internal service: vendor outages become my outages, and vendor pricing changes force migration under pressure. The self-hosted tooling is mature enough to make this a reasonable trade.

**Why not another self-hosted option?**

- **[Authelia](https://www.authelia.com/)** is well-suited to forward auth proxy protection, but has no OpenTofu (see [ADR-002](ADR-002-opentofu-terragrunt.md)) provider. Every integration is a hand-edited YAML file, and an IdP that cannot be expressed as code is the wrong tool where IaC reproducibility is non-negotiable. It also lacks native application-level authorization policies
- **[Keycloak](https://www.keycloak.org/)** covers every protocol with a large ecosystem, but targets organizations managing thousands of users: it needs a JVM, has a heavier database footprint, and its Terraform/OpenTofu provider has historically lagged behind the API. The complexity-to-value ratio is wrong for a homelab with a handful of users
- **[Zitadel](https://zitadel.com/)** is worth considering: Go-based, API-first, good documentation. Its OpenTofu provider is less mature than Authentik's, and homelab integration guides for specific apps (Grafana, ArgoCD, Proxmox, Immich) are significantly thinner. It stays a credible fallback if Authentik's direction changes

**Integration model:** Not all apps speak OpenID Connect (OIDC). Apps with native OIDC support (Grafana, ArgoCD, Proxmox) use their own Authentik provider. Apps without native Single Sign-On (SSO) sit behind forward auth: Cilium's (see [ADR-005](ADR-005-cilium-gateway-api.md)) Gateway API checks each request with the Authentik embedded outpost before passing it through, so the app itself does not know authentication happens upstream.

**Operational risk:** A self-hosted IdP is one of the highest-stakes components in the stack. If Authentik is down, every forward-auth-protected service is inaccessible. If the database is lost, MFA enrollment state for every user is gone, see [ADR-015](ADR-015-disaster-recovery.md) for the recovery path. The cost is accepted because per-app credential sprawl is also a security risk, only a quieter one. The mitigation is durability, not redundancy.

## Decision

I will use [Authentik](https://goauthentik.io/) as the homelab identity provider, deployed on Kubernetes backed by a CloudNativePG (see [ADR-006](ADR-006-cloudnativepg.md)) cluster.

Authentik's configuration (applications, providers, flows, policies, outposts) is managed entirely through the [`goauthentik/terraform`](https://registry.terraform.io/providers/goauthentik/authentik/latest/docs) OpenTofu provider under `infrastructure/units/public/authentik/`. Adding a new application is a [`terragrunt apply`](https://terragrunt.gruntwork.io/), not a UI operation. The reusable application pattern (provider resource, application resource, default access policy) is a catalog module under `infrastructure/catalogs/public/authentik-app/`, instantiated once per app.

Apps with native OIDC use their own Authentik provider and handle the redirect flow themselves. Apps without native SSO get a Cilium `ExtensionRef` forward auth filter on their HTTPRoute pointing at the Authentik embedded outpost. Proxmox is configured via its native OpenID Connect realm type, with group-to-role mapping through the realm configuration. The PAM root account stays offline as a break-glass credential.

The Authentik CNPG cluster uses the `longhorn` StorageClass (see [ADR-007](ADR-007-longhorn.md)) (3 replicas) and Barman (see [ADR-006](ADR-006-cloudnativepg.md)) backup to Garage (see [ADR-010](ADR-010-garage.md)) S3 from day one. Redis, used for session caching and task queuing, uses `longhorn-single-replica` because its data is reproducible.

Migration from the existing docker-compose instance follows an export/import path via Authentik's built-in system export. Active sessions and Time-based One-Time Password (TOTP) enrollments do not survive it, so users re-authenticate and re-enroll MFA. That is acceptable for a small user base and gets communicated before cutover.

## Consequences

**Positive:**

- Every service in the stack sits behind the same identity perimeter, whether or not it has native SSO support
- Adding an application is a [`terragrunt apply`](https://terragrunt.gruntwork.io/), and UI state stays in sync with code because code is the authoritative source
- MFA is enforced uniformly, and access revocation is a single operation in one place
- Proxmox management access runs through Authentik OIDC, so normal operation needs no separate local accounts
- ArgoCD is not exposed via the Gateway until Authentik OIDC is live. `kubectl port-forward` is used during [Phases 1–5](../../README.md#phases), and the admin password is SOPS (see [ADR-009](ADR-009-sops.md))-encrypted immediately after install

**Negative:**

- Authentik is a single point of failure for all forward-auth-protected services. Apps with native OIDC that cache tokens locally may stay up for the token lifetime, but forward-auth services go down with it. The mitigation is a reliable, durable deployment rather than redundancy
- The Barman backup strategy must be verified and working before this counts as production. Until [Phase 9](../../README.md#phases) (disaster recovery) is complete, simultaneous failure of all Longhorn replicas means MFA state is unrecoverable
- The OpenTofu provider trails the Authentik application on new features. Test major Authentik upgrades against the provider before rollout. Renovate (see [ADR-004](ADR-004-renovate.md)) manages version bumps but cannot catch provider gaps
- The Cilium `ExtensionRef` forward auth integration point is evolving. Verify the field names and filter syntax against current Cilium documentation at deploy time
- The docker-compose Authentik instance runs in parallel only during migration. Running both long-term is not supported
