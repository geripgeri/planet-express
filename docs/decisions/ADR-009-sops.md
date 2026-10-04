# ADR-009: Secret Management with SOPS and age

## Status

Accepted

## Context

Full IaC reproducibility is the project goal, see [ADR-000](ADR-000-project-goals.md) for the principle behind it: git plus a blank machine plus documented bootstrap steps must rebuild everything. Secrets work against that goal. Secrets outside the repository leave the repo an incomplete description of the system and force manual retrieval on rebuild. Secrets committed in plaintext turn the public GitHub / Codeberg mirror into a security liability and defeat the portfolio goal. The resolution is encrypted secrets in the repository: ciphertext in git is safe to publish, present for a full rebuild, and meaningful in version history.

**Threat model:** The primary threat is accidental credential exposure in a public git repository. Any plaintext credential reachable by `git log` is permanently compromised after a push to a public remote. The secondary threat is credential theft from a compromised workstation scanning common file locations. Compromise of the age private key is a key management problem, not a tooling one, and is out of scope here.

**What is encrypted in the repository:**

- OpenTofu provider credentials (Hetzner Object Storage, AdGuard, Authentik, Garage S3), see [ADR-002](ADR-002-opentofu-terragrunt.md) for the provisioning layer
- Ansible host variables containing API credentials, see [ADR-016](ADR-016-ansible-for-proxmox-host-configuration.md) for the host configuration boundary
- Kubernetes Secret manifests (database passwords, OIDC client secrets, webhook tokens)
- Helm values files (`values.secret.yaml`) alongside standard values files

**What stays outside the repository entirely:**

- `talosconfig` and Talos `secrets.yaml`: cluster root credentials. A compromised `talosconfig` gives full API access to Talos nodes, including the ability to wipe them. The blast radius is too high to accept even encrypted in git
- The age private key itself

## Decision

I will use [SOPS](https://github.com/getsops/sops) with [age](https://age-encryption.org/) as the encryption backend for all secrets in this repository.

SOPS encrypts individual values within YAML, JSON, ENV, and INI files rather than whole files. Structure and keys stay in plaintext, only values become ciphertext. Encrypted files stay diff-able and reviewable in pull requests, so a secret change shows as a change at the correct path in git history, not a binary diff of an opaque blob.

age is a file encryption tool ([X25519](https://cr.yp.to/ecdh.html)/[ChaCha20-Poly1305](https://datatracker.ietf.org/doc/html/rfc8439)) with a minimal interface and no keyserver dependency. Multiple age public keys can be recipients on the same encrypted file, so a CI runner holds its own key without sharing the developer key.

**Configuration:** `.sops.yaml` at the repository root maps path patterns to age public keys:

```yaml
creation_rules:
  - path_regex: ansible/host_vars/.*\.yml$
    age:
  - path_regex: ansible/group_vars/.*\.yml$
    age:
  - path_regex: kubernetes/.*\.secret\.yaml$
    age:
  - path_regex: infrastructure/units/.*\.secret\.tfvars$
    age:
```

**Naming conventions:** `values.secret.yaml` for Helm charts, `*.secret.tfvars` for OpenTofu, whole-file encryption for Ansible variable files (they tend to be small and credential-heavy).

**Runtime decryption:**

- ArgoCD (see [ADR-003](ADR-003-argocd.md)): [native SOPS integration](https://argo-cd.readthedocs.io/en/stable/operator-manual/secret-management/) (v2.9+); age key bootstrapped as a Kubernetes Secret before the GitOps loop starts
- OpenTofu/Terragrunt (see [ADR-002](ADR-002-opentofu-terragrunt.md)): `sops_decrypt_file()` or `sops` CLI via `read_terragrunt_config()`; age key in `SOPS_AGE_KEY` or `~/.config/sops/age/keys.txt`
- Ansible (see [ADR-016](ADR-016-ansible-for-proxmox-host-configuration.md)): [`ansible-community/ansible-sops`](https://github.com/ansible-collections/community.sops) lookup plugin; age key in the environment on the control machine

**[gitleaks](https://github.com/gitleaks/gitleaks):** A pre-commit hook scans staged content for plaintext secrets and blocks commits matching known secret formats. It catches credentials that were never encrypted in the first place. SOPS-encrypted values that trigger false positives are suppressed in `.gitleaks.toml`.

**Alternatives rejected:** HashiCorp Vault (see [ADR-001](ADR-001-kubernetes.md)) and [External Secrets Operator](https://external-secrets.io/) externalise secrets, which breaks the reproducibility goal and adds bootstrap dependency problems. [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets) is Kubernetes-only with no answer for Terraform or Ansible variable files. Ansible Vault is likewise scoped to Ansible only. GPG as the SOPS backend adds keyring complexity with no benefit for a single-recipient setup.

## Consequences

- The repository is fully self-contained: a rebuild from git needs only the age private key
- The public GitHub / Codeberg (see [ADR-002](ADR-002-opentofu-terragrunt.md)) mirror is safe to publish without filtering
- The age private key is the single access control boundary. Losing it means losing access to all encrypted secrets, the same as losing a password manager master password. The key lives in a password manager with an optional encrypted USB copy
- Rotating a compromised secret takes decrypt, change, re-encrypt, commit, and revocation at the provider. Git history keeps the old ciphertext, so the old plaintext credential must be revoked separately and SOPS does not help there
- CI runners that decrypt secrets should use a dedicated age key pair added as a recipient in the relevant SOPS creation rules, not the developer key, so a compromised runner key gets removed without rotating the developer key
- `talosconfig` and Talos `secrets.yaml` are out of scope for this ADR. Their management is documented in `docs/runbooks/cluster-rebuild.md`
- gitleaks produces false positives for SOPS-encrypted values whose structure matches known secret patterns, and `.gitleaks.toml` suppresses them. Add new SOPS output patterns there rather than disabling the hook

### Amendment (March 2026): Post-quantum age keys deferred

Post-quantum ([ML-KEM](https://csrc.nist.gov/pubs/fips/203/final)) age keys were the original intent. A Terragrunt bug ([#5759](https://github.com/gruntwork-io/terragrunt/issues/5759)) prevents Terragrunt from invoking SOPS correctly with the PQ recipient format.

**Interim decision:** Standard age (X25519) keys only.

GPG was considered and rejected as an interim: keyring management overhead is not justified for a temporary state. Classical age keys keep the migration path clean, which is `sops --rotate --in-place` against all encrypted files after updating `.sops.yaml` to reference the new PQ public key.

**On git history:** Historical commits keep X25519-wrapped ciphertexts after migration, and re-encrypting HEAD does not retroactively protect them. Rotating all API keys and credentials at migration time closes the exposure, because a future adversary decrypting a historical ciphertext recovers a dead credential. No long-term identity material (CA private keys, etc.) is stored in SOPS, so rotation is sufficient. The interim period is an accepted, bounded risk for a private homelab repository.

**Migration steps when [#5759](https://github.com/gruntwork-io/terragrunt/issues/5759) is resolved:**

1. Generate new PQ age key pair
2. Update `.sops.yaml` with the new public key
3. `sops --rotate --in-place` all encrypted files
4. Rotate all stored API keys, tokens, and passwords
5. Store the new private key in the password manager
6. Revoke the old classical age key

### Amendment (April 2026): Migrated to ML-KEM post-quantum age keys

Terragrunt issue [#5759](https://github.com/gruntwork-io/terragrunt/issues/5759) is resolved. The `sops_decrypt_file()` function now handles the ML-KEM post-quantum recipient format correctly.

The March 2026 migration steps have been completed:

1. Generated a new ML-KEM age key pair (`age-keygen -pq`)
2. Updated `.sops.yaml` with the new public key
3. `sops --rotate --in-place` run against all encrypted files
4. All stored API keys, tokens, and passwords rotated
5. New private key stored in the password manager
6. Old X25519 key revoked

Historical commits retain X25519-wrapped ciphertexts, and the credential rotation in step 4 closes that exposure: any historical ciphertext a future adversary decrypts yields a dead credential.
