# ADR-008: Authentik as the Identity Provider

## Status

Active

## Context

A homelab running a dozen self-hosted services has a credential management problem. Each app handles its own authentication: separate passwords, inconsistent MFA coverage, and no central place to revoke access. Password reuse across services is a real risk; adding a new app means adding another credential to manage.

The solution is a centralized identity provider. Every app delegates authentication to it. Revoking access happens once. MFA is enforced at the IdP level, not left to each app to implement independently.

**Why not a managed IdP?** [Cloudflare Access](https://www.cloudflare.com/zero-trust/products/access/), [Okta](https://www.okta.com/), and [Auth0](https://auth0.com/) solve the problem without the operational burden, but self-hosting is a project goal (see [ADR-000](ADR-000-project-goals.md)). A managed IdP introduces an external dependency in the auth path of every internal service: vendor outages become my outages, and vendor pricing changes force migration under pressure. The self-hosted tooling is mature enough to make this a reasonable trade.

**Why not one of the other self-hosted options?**

- **[Authelia](https://www.authelia.com/)** is well-suited for forward auth proxy protection but has no OpenTofu (see [ADR-002](ADR-002-opentofu-terragrunt.md)) provider. Every integration is a hand-edited YAML file. For a stack where IaC reproducibility is non-negotiable, an IdP that can't be expressed as code is the wrong tool. It also lacks native application-level authorization policies.
- **[Keycloak](https://www.keycloak.org/)** covers every protocol and has a large ecosystem, but it's designed for organizations managing thousands of users. It requires a JVM, has a heavier database footprint, and its Terraform/OpenTofu provider has historically lagged behind the API. The complexity-to-value ratio is wrong for a homelab that will never exceed a handful of users.
- **[Zitadel](https://zitadel.com/)** is genuinely worth considering: Go-based, API-first, good documentation. Its OpenTofu provider is less mature than Authentik's, and the homelab community's integration guides for specific apps (Grafana, ArgoCD, Proxmox, Immich) are significantly thinner. Zitadel remains a credible fallback if Authentik's direction changes.

**Integration model:** Not all apps speak OpenID Connect (OIDC). Apps with native OIDC support (Grafana, ArgoCD, Proxmox) are configured as OIDC relying parties pointing at [Authentik](https://goauthentik.io/). Apps without native Single Sign-On (SSO) are protected via forward auth: Cilium's (see [ADR-005](ADR-005-cilium-gateway-api.md)) Gateway API (see [ADR-005](ADR-005-cilium-gateway-api.md)) intercepts each request and checks with the Authentik embedded outpost before passing it through. The app itself is unaware authentication is happening upstream.

**Operational risk:** A self-hosted IdP is one of the highest-stakes components in the stack. If Authentik is down, every forward-auth-protected service is inaccessible. If the database is lost, MFA enrollment state for every user is gone. This cost is accepted because per-app credential sprawl is also a security risk; it's just a quieter one. The mitigation is durability instead of redundancy.

## Decision

I will use [Authentik](https://goauthentik.io/) as the homelab identity provider, deployed on Kubernetes backed by a CloudNativePG (see [ADR-006](ADR-006-cloudnativepg.md)) cluster.

Authentik's configuration (applications, providers, flows, policies, outposts) is managed entirely via the [`goauthentik/terraform`](https://registry.terraform.io/providers/goauthentik/authentik/latest/docs) OpenTofu provider under `infrastructure/units/public/authentik/`. Adding a new application is a [`terragrunt apply`](https://terragrunt.gruntwork.io/), not a UI operation. The reusable pattern for an application (provider resource, application resource, default access policy) is defined as a catalog module under `infrastructure/catalogs/public/authentik-app/` and instantiated once per app.

Apps with native OIDC use their own Authentik provider and handle the redirect flow themselves. Apps without native SSO get a Cilium `ExtensionRef` forward auth filter on their HTTPRoute pointing at the Authentik embedded outpost. Proxmox is configured via its native OpenID Connect realm type, with group-to-role mapping through the realm configuration. The PAM root account is kept offline as a break-glass credential.

The Authentik CNPG cluster uses the `longhorn` StorageClass (see [ADR-007](ADR-007-longhorn.md)) (3 replicas) and Barman (see [ADR-006](ADR-006-cloudnativepg.md)) backup to Garage (see [ADR-010](ADR-010-garage.md)) S3 from day one. Redis, used for session caching and task queuing, uses `longhorn-single-replica` since its data is reproducible.

Migration from the existing docker-compose instance follows an export/import path via Authentik's built-in system export. Active sessions and Time-based One-Time Password (TOTP) enrollments do not survive the migration; users will re-authenticate and re-enroll MFA. This is acceptable for a small user base and will be communicated before cutover.

## Consequences

**Positive:**

- Every service in the stack is behind the same identity perimeter, regardless of whether it has native SSO support.
- Adding an application is a [`terragrunt apply`](https://terragrunt.gruntwork.io/). The UI state and code state stay in sync because code is the authoritative source.
- MFA is enforced uniformly. Access revocation is a single operation in one place.
- Proxmox management access runs through Authentik OIDC. No separate local accounts are needed for normal operation.
- ArgoCD is not exposed via the Gateway until Authentik OIDC is live; `kubectl port-forward` is used during [Phases 1–5](../../README.md#phases) and the admin password is SOPS (see [ADR-009](ADR-009-sops.md))-encrypted immediately after install.

**Negative:**

- Authentik is a single point of failure for all forward-auth-protected services. Apps with native OIDC that cache tokens locally may stay up for the token lifetime, but forward-auth services go down with it. The mitigation is a reliable, durable deployment rather than redundancy.
- The Barman backup strategy must be verified and working before this is treated as production. Until [Phase 9](../../README.md#phases) (disaster recovery) is complete, simultaneous failure of all Longhorn replicas means MFA state is unrecoverable.
- The OpenTofu provider trails the Authentik application on new features. Major Authentik upgrades should be tested against the provider before rollout; Renovate (see [ADR-004](ADR-004-renovate.md)) manages version bumps but can't catch provider gaps.
- The Cilium `ExtensionRef` forward auth integration point is evolving. The specific field names and filter syntax should be verified against current Cilium documentation at deploy time.
- The docker-compose Authentik instance runs in parallel only during migration. Running both long-term is not supported.
