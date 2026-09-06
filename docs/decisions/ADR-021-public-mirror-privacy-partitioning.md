# ADR-021: Public-Mirror Privacy Partitioning with export-ignore Private Subtrees

## Status

Accepted

## Context

This repository publishes a filtered mirror to GitHub. The [mirror workflow](../../.gitea/workflows/mirror.yaml) clones the internal Gitea repository, parses every `.gitattributes` `export-ignore` path into `git-filter-repo --invert-paths` arguments, rewrites history with those paths stripped, runs [gitleaks](https://github.com/gitleaks/gitleaks) over the filtered history, and pushes the result to GitHub. Secret management with SOPS (see [ADR-009](ADR-009-sops.md)) already guarantees that committed credentials are ciphertext, so plaintext secrets were never the exposure class in question here. Structure was.

Writing the working Longhorn and cert-manager configuration made the problem concrete. Those files name the managed-DNS provider directly (the ACME `dns01` solver block in the cert-manager `ClusterIssuer`), carry the real wildcard domain in HTTPRoute `hostnames`, and record load balancer IP ranges, LAN CIDRs, and physical interface names. Longhorn storage topology adds more of the same. Each value alone looks harmless. Read together they map the homelab's perimeter: provider, domain, address plan, and network layout in one public tree. That is a compounding OSINT signal set, published continuously, for a repository whose stated purpose includes being reviewed by strangers.

Two alternatives were considered and rejected.

**Encrypt the sensitive values only.** Rejected. The sensitive positions are schema-fixed plaintext: a cert-manager `ClusterIssuer` solver block is not a `Secret`, and HTTPRoute `hostnames` must be literal strings. Hiding these values through SOPS would require ksops-style replacement generators or templating around every affected manifest. That multiplies moving parts across the GitOps tree (see [ADR-003](ADR-003-argocd.md)) and couples each chart upgrade to a decryption shim, all to protect values that routing correctness depends on.

**Accept the visibility.** Rejected. Presenting the repository publicly while keeping the home network unmapped is a standing owner requirement. The cost of meeting it is one directory convention, so paying nothing to avoid the exposure is not available.

## Decision

I will partition privacy-sensitive configuration into dedicated `private/` subtrees, excluded from the public mirror by `export-ignore` entries in `.gitattributes`. The partition rule: any file naming the DNS provider, containing the real wildcard domain, or carrying real network identifiers (load balancer IP pools, LAN CIDRs, interface names) lives under a `private/` subtree. The current exclusion list covers `infrastructure/catalogs/private/`, `infrastructure/stacks/private/`, `infrastructure/units/private/`, `kubernetes/apps/private/`, and `kubernetes/infrastructure/private/`.

The public tree keeps full structure, ADRs, runbooks, and examples. Examples use RFC 5737 documentation addresses (TEST-NET ranges) and placeholder domains only. Sanitized content lives exclusively in documentation prose; no parallel sanitized copies of live manifests exist in the public tree.

Deployment does not go through the mirror. ArgoCD clones the internal Gitea repository directly over the LAN with a full, unfiltered checkout (see the bootstrap design in [ADR-003](ADR-003-argocd.md)), so manifests under `private/` paths apply like any other Application source. Gateway API routing (see [ADR-005](ADR-005-cilium-gateway-api.md)) resolves its wildcard certificate from the private cert-manager configuration at sync time. Filtering is a publication-boundary concern only.

## Consequences

**Positive:**

- The public mirror presents architecture, conventions, and operational practice without publishing the home network's address plan
- Hiding a new sensitive file costs one directory choice: place it under the relevant `private/` subtree, with no encryption shim, no template indirection, and no change to how ArgoCD consumes it
- Manifests stay plain YAML throughout; no ksops plugins sit in the reconciliation path
- gitleaks still scans the filtered history before push, providing a second layer behind the structural filter

**Negative / trade-offs:**

- The public repository alone no longer rebuilds the cluster; a rebuild requires access to the internal Gitea repository. Reproducibility from git (see [ADR-009](ADR-009-sops.md)) holds for the internal repository, not for the mirror
- Two similar-looking trees invite drift: someone could edit a remembered sanitized value believing it drives the cluster. Mitigated by keeping sanitized examples in documentation prose only, never as parallel manifest files, so no editable public twin of a live manifest exists
- `git-filter-repo` rewrites history, so commit hashes diverge between Gitea and GitHub after each mirror run; the mirror is a snapshot, not a shared history

______________________________________________________________________

### Amendment: August 2026 — Scope narrowed to topology and credentials

The original rule partitioned anything naming the DNS provider, the real
domain, or real network identifiers. Operating it surfaced two facts that
changed the calculus.

First, provider and domain were never actually concealable. Every Let's
Encrypt certificate is published to [Certificate Transparency](https://certificate.transparency.dev/) logs, searchable on [crt.sh](https://crt.sh) within minutes of issuance; the `*.peidl.net` wildcard is a public infrastructure record regardless of repository content. The domain's NS records point at the DNS provider — one `dig NS peidl.net` from any network. Repository-level hiding therefore bought obscurity against casual readers only, at the cost of placeholder friction in every TLS manifest.

Second, this repository is a portfolio first (see [ADR-000](ADR-000-project-goals.md)). The cert-manager DNS-01 wildcard flow is a standard production pattern; showing it working end to end demonstrates more than hiding it protects.

**Revised rule:** the `private/` partition covers internal network topology (address plans, LB pools, interface names, VPN zone policy) and all credential material. Provider identity and public domain literals are allowed in the public tree. The TLS routing manifests (ClusterIssuer, wildcard Certificate, shared Gateway, HTTPRoutes) moved to the public `kubernetes/infrastructure/networking/` directory; topology manifests stay under `kubernetes/infrastructure/private/network/`, which remains export-ignored. The gitleaks IP rules keep their allowlist for that tree.

Neutral resource names adopted during the interim (`dns01-api-token`) stay: they are accurate descriptions, not obfuscation, and renaming again would churn references for no gain.
