# Infra Rulebook

**Version:** v1.0 **Purpose:** Actionable infrastructure rules derived from all ADRs in this homelab project. **How to use:** When provisioning, coding, or reviewing, check that your change satisfies every applicable rule. If a rule cannot be followed, follow the Conflicts & Exceptions process below.

______________________________________________________________________

## Rules

______________________________________________________________________

### [ADR-000](decisions/ADR-000-project-goals.md) — Project Goals & Principles

______________________________________________________________________

**Rule IaC-01: Express every infrastructure resource as code.** **Source:** ([ADR-000](decisions/ADR-000-project-goals.md)) **Rationale:** A git repository plus runbooks must be sufficient to rebuild the entire stack from scratch on a blank machine. **Implementation:**

- No manual clicks in Proxmox UI, no `kubectl apply` outside of bootstrap; all changes go through OpenTofu, Ansible, or ArgoCD
- Definition of done for any phase: a stranger can clone the repo, follow the runbook, and reproduce the result
- TODO: add a CI gate that fails if any resource in `infrastructure/` is missing a corresponding OpenTofu unit

**Tags:** iac, gitops, process

______________________________________________________________________

**Rule IaC-02: Write ADRs at decision time, not after.** **Source:** ([ADR-000](decisions/ADR-000-project-goals.md)) **Rationale:** Documentation written after the fact diverges from reality; decisions made under pressure are the ones most likely to be forgotten. **Implementation:**

- ADR is a required deliverable before merging any architectural change
- Known gaps and failed attempts must be documented explicitly, not omitted
- ADR format: `ADR-NNN-short-title.md` under `docs/decisions/`

**Tags:** process, documentation

______________________________________________________________________

**Rule IaC-03: Run two-tier CI on every PR.** **Source:** ([ADR-000](decisions/ADR-000-project-goals.md)) **Rationale:** Static tests catch format and syntax errors fast; integration tests catch provider-level regressions that linting cannot find. **Implementation:**

- Tier 1 (static, hosted runners): `tofu validate`, `tofu fmt`, `yamllint`, `ansible-lint`
- Tier 2 (integration, self-hosted runner): Terratest Go tests against real Proxmox API — provision, assert, destroy
- Integration tests are scoped to catalog modules only, never to production units

**Tags:** ci, iac, testing

______________________________________________________________________

**Rule IaC-04: Publish selectively using `.gitattributes` export-ignore.** **Source:** ([ADR-000](decisions/ADR-000-project-goals.md)) **Rationale:** Catalog patterns can be public (portfolio value) while live unit config with IPs and credentials stays private. **Implementation:**

- `catalogs/public/` and `units/public/` → mirrored to GitHub and Codeberg
- `catalogs/private/` and `units/private/` → excluded via `.gitattributes` export-ignore with `git-filter-repo`
- Verify mirror contents before each public push: `git archive HEAD | tar -t | grep private` should return empty

**Tags:** security, portfolio, iac

______________________________________________________________________

### [ADR-001](decisions/ADR-001-kubernetes.md) — Kubernetes Platform

______________________________________________________________________

**Rule K8S-01: Use Talos Linux as the Kubernetes node OS.** **Source:** ([ADR-001](decisions/ADR-001-kubernetes.md)) **Rationale:** Talos has no SSH, no shell, and no package manager, enforcing IaC discipline at the OS layer and minimising attack surface. **Implementation:**

- All node config changes go through `talosctl apply-config` with machine config patches committed to git
- Never install packages or make runtime changes directly on a Talos node
- `talosconfig` and `secrets.yaml` are stored outside git (see [ADR-009](decisions/ADR-009-sops.md))

**Tags:** kubernetes, security, iac

______________________________________________________________________

**Rule K8S-02: Never use `kubectl apply` in normal operations.** **Source:** ([ADR-001](decisions/ADR-001-kubernetes.md), [ADR-003](decisions/ADR-003-argocd.md)) **Rationale:** Manual applies bypass the GitOps reconciliation loop and create state drift that is invisible until something breaks. **Implementation:**

- All workloads are managed by ArgoCD; changes go through git commits and ArgoCD sync
- Permitted exception: bootstrap operations (ArgoCD install, Cilium install) that must precede the GitOps loop — documented in `docs/runbooks/`
- Break-glass `kubectl apply` requires a follow-up git commit to reconcile state before the runbook is closed

**Tags:** kubernetes, gitops, process

______________________________________________________________________

**Rule K8S-03: Run non-Kubernetes services as Proxmox LXCs or VMs.** **Source:** ([ADR-001](decisions/ADR-001-kubernetes.md)) **Rationale:** Services with lifecycle or networking requirements independent of the cluster (DNS, object storage, NFS) should not create circular dependencies with the scheduler. **Implementation:**

- Services that must precede cluster bootstrap (Garage, AdGuard) run as LXCs
- Services with kernel-level requirements (NFS server, fan control) run as LXCs managed by Ansible
- Kubernetes is not used for workloads where "the cluster is down" and "the service is down" should be independent events

**Tags:** kubernetes, architecture

______________________________________________________________________

### [ADR-002](decisions/ADR-002-opentofu-terragrunt.md) — OpenTofu + Terragrunt

______________________________________________________________________

**Rule TF-01: Use OpenTofu, not Terraform.** **Source:** ([ADR-002](decisions/ADR-002-opentofu-terragrunt.md)) **Rationale:** Terraform is BSL-licensed; OpenTofu is the CNCF-backed MPL-2.0 fork and is drop-in compatible with all providers used here. **Implementation:**

- Binary: `tofu`, not `terraform`
- Lock files: `use_lockfile = true` in all backend configs (replaces DynamoDB locking)
- All provider references use the same registry paths — no migration needed from Terraform HCL

**Tags:** iac, open-source

______________________________________________________________________

**Rule TF-02: Follow the catalog/stack/unit pattern via Terragrunt.** **Source:** ([ADR-002](decisions/ADR-002-opentofu-terragrunt.md)) **Rationale:** A flat OpenTofu layout puts all resources in one state file and requires duplicating backend config across every directory. **Implementation:**

- Catalog modules live in `infrastructure/catalogs/` — pure HCL, no live values, safe to publish
- Units live in `infrastructure/units/` — one `terragrunt.hcl` per resource, one state file per unit
- Stacks live in `infrastructure/stacks/` — declare dependency order and wire outputs between units via `terragrunt.stack.hcl`

**Tags:** iac, structure

______________________________________________________________________

**Rule TF-03: Remote state in Garage S3 from the first provisioned resource.** **Source:** ([ADR-002](decisions/ADR-002-opentofu-terragrunt.md), [ADR-010](decisions/ADR-010-garage.md)) **Rationale:** Local state is never canonical; it is not committed to git and is lost if the workstation is lost. **Implementation:**

- Backend config is defined once in `root.hcl` and inherited by all units
- `use_lockfile = true` replaces DynamoDB; Garage supports the required `PutObject`/`DeleteObject` ops
- Incremental migration: each unit is moved to remote state individually and verified before the next

**Tags:** iac, state

______________________________________________________________________

### [ADR-003](decisions/ADR-003-argocd.md) — ArgoCD GitOps

______________________________________________________________________

**Rule GIT-01: Bootstrap ArgoCD once via OpenTofu `null_resource`, then make it self-managing.** **Source:** ([ADR-003](decisions/ADR-003-argocd.md)) **Rationale:** GitOps has a chicken-and-egg bootstrap problem; the one-time imperative step must be isolated and documented. **Implementation:**

- Bootstrap command: `helm upgrade --install argocd` invoked by OpenTofu `null_resource` in the cluster stack
- Immediately after bootstrap: create an ArgoCD Application pointing at `kubernetes/infrastructure/argocd/` so future changes are GitOps-managed
- Break-glass runbook: `docs/runbooks/argocd-breakglass.md` — required deliverable before [Phase 1](../README.md#phases) is complete

**Tags:** gitops, kubernetes, bootstrap

______________________________________________________________________

**Rule GIT-02: Use the App of Apps pattern for workload discovery.** **Source:** ([ADR-003](decisions/ADR-003-argocd.md)) **Rationale:** An ApplicationSet that discovers Applications by directory means adding a new service requires only a git commit — no Helm command, no manual sync trigger. **Implementation:**

- Root Application manages all child Applications by directory structure under `kubernetes/apps/` and `kubernetes/infrastructure/`
- ApplicationSet controller (`argocd-applicationset`) must be enabled in the ArgoCD Helm values
- Adding a new service: create the directory, commit; the ApplicationSet picks it up on the next sync

**Tags:** gitops, kubernetes

______________________________________________________________________

**Rule GIT-03: Do not expose the ArgoCD UI until Authentik OIDC is live.** **Source:** ([ADR-003](decisions/ADR-003-argocd.md)) **Rationale:** The ArgoCD web UI is an attack surface; exposing it before SSO means credentials are the only protection. **Implementation:**

- During Phases 1–5: access via `kubectl port-forward svc/argocd-server -n argocd 8080:443`
- Admin password: SOPS-encrypted immediately after bootstrap (see [ADR-009](decisions/ADR-009-sops.md))
- Gateway API `HTTPRoute` for ArgoCD is only created in Phase 5/6 when Authentik OIDC is configured

**Tags:** security, gitops

______________________________________________________________________

### [ADR-004](decisions/ADR-004-renovate.md) — Renovate

______________________________________________________________________

**Rule DEP-01: Deploy Renovate as a nightly scheduled Gitea Actions workflow on a self-hosted runner.** **Source:** ([ADR-004](decisions/ADR-004-renovate.md)) **Rationale:** The private Gitea instance is LAN-only; Mend-hosted Renovate cannot reach it. **Implementation:**

- Schedule: `cron: '0 3 * * *'` plus `workflow_dispatch` for on-demand runs
- Config file: `renovate.json` at repo root with `argocd`, `helm-values`, and `terraform` managers enabled
- Runner: self-hosted, same runner registered for integration tests

**Tags:** dependencies, ci

______________________________________________________________________

**Rule DEP-02: Automerge minor and patch updates; require manual review for major bumps.** **Source:** ([ADR-004](decisions/ADR-004-renovate.md)) **Rationale:** Major version bumps carry breaking change risk that a CI suite alone cannot catch reliably. **Implementation:**

- `renovate.json` extends `":automergeMinor"` and `"config:recommended"`
- Major bumps open a PR and are blocked from automerge; changelog review is expected before merge
- Cilium chart bumps (Gateway API behaviour can change between minor versions) should include changelog review even for minor updates

**Tags:** dependencies, ci

______________________________________________________________________

**Rule DEP-03: Keep Dependabot active on the public GitHub/Codeberg mirror.** **Source:** ([ADR-004](decisions/ADR-004-renovate.md)) **Rationale:** Dependabot provides passive CVE coverage via the GitHub Advisory Database with zero configuration overhead on public repos. **Implementation:**

- No `dependabot.yml` configuration needed for public repos — GitHub enables it automatically
- Dependabot and Renovate do not conflict: Renovate bumps proactively, Dependabot flags security issues reactively
- Do not disable Dependabot on the mirror to "keep PRs clean"

**Tags:** security, dependencies

______________________________________________________________________

### [ADR-005](decisions/ADR-005-cilium-gateway-api.md) — Cilium Gateway API

______________________________________________________________________

**Rule NET-01: Use Cilium's built-in Gateway API controller; deploy no separate ingress controller.** **Source:** ([ADR-005](decisions/ADR-005-cilium-gateway-api.md)) **Rationale:** ingress-nginx reached EOL in March 2026; the `Ingress` API is frozen; Cilium already handles L3/L4 — a second L7 proxy duplicates without adding value. **Implementation:**

- No `kind: Ingress` resources anywhere in the cluster
- All HTTP/HTTPS routing uses `GatewayClass`, `Gateway`, and `HTTPRoute` resources
- Verify Cilium Gateway API support is enabled: `helm values cilium | grep gatewayAPI.enabled` must be `true`

**Tags:** networking, kubernetes

______________________________________________________________________

**Rule NET-02: Terminate TLS at a single shared Gateway using a wildcard cert.** **Source:** ([ADR-005](decisions/ADR-005-cilium-gateway-api.md)) **Rationale:** Centralising TLS at the Gateway means applications write only an `HTTPRoute`; no per-service cert or listener configuration is needed. **Implementation:**

- Shared Gateway lives in `kube-system`; wildcard cert `*.yourdomain.internal` provisioned by cert-manager via DNS-01
- Application `HTTPRoute` specifies only `hostname` and `backendRef` — no TLS stanza
- cert-manager `Certificate` resource committed to `kubernetes/infrastructure/cert-manager/`

**Tags:** networking, security, tls

______________________________________________________________________

**Rule NET-03: Use Authentik `ExtensionRef` forward auth for services without native OIDC; use native OIDC for services that support it.** **Source:** ([ADR-005](decisions/ADR-005-cilium-gateway-api.md), [ADR-008](decisions/ADR-008-authentik.md)) **Rationale:** Forward auth via `ExtensionRef` is the only path for apps without SSO support; native OIDC preserves role mapping and group sync. **Implementation:**

- Native OIDC apps (Grafana, ArgoCD, Proxmox): configure `auth.generic_oauth` or equivalent directly
- Non-OIDC apps: add `ExtensionRef` filter on `HTTPRoute` pointing at the Authentik embedded outpost
- Verify `ExtensionRef` filter syntax against the Cilium version deployed — syntax changed between 1.13 and 1.14

**Tags:** networking, security, authentication

______________________________________________________________________

### [ADR-006](decisions/ADR-006-cloudnativepg.md) — CloudNativePG

______________________________________________________________________

**Rule DB-01: Every application requiring Postgres gets its own dedicated CNPG `Cluster` resource.** **Source:** ([ADR-006](decisions/ADR-006-cloudnativepg.md)) **Rationale:** Shared Postgres clusters conflate failure blast radius, connection limits, and schema evolution across unrelated applications. **Implementation:**

- No shared Postgres; no ad-hoc `kubectl exec psql`
- Each `Cluster` manifest lives under `kubernetes/apps/<app-name>/`
- `Cluster` resource is committed to git before the application is deployed

**Tags:** database, kubernetes

______________________________________________________________________

**Rule DB-02: Configure Barman WAL archiving on every CNPG Cluster at creation time.** **Source:** ([ADR-006](decisions/ADR-006-cloudnativepg.md), [ADR-015](decisions/ADR-015-disaster-recovery.md)) **Rationale:** There must be no window during which a cluster exists without backup coverage; adding Barman retroactively leaves a gap. **Implementation:**

- `backup.barmanObjectStore` must be present in every `Cluster` manifest
- Target: Garage S3 bucket provisioned in Phase 0.9 (see [ADR-010](decisions/ADR-010-garage.md))
- Enforced as a pattern in the `k8s-app` catalog module — TODO: add a Kyverno policy to reject `Cluster` resources missing `backup.barmanObjectStore`

**Tags:** database, backup, kubernetes

______________________________________________________________________

**Rule DB-03: Assign StorageClass to CNPG Clusters based on recoverability.** **Source:** ([ADR-006](decisions/ADR-006-cloudnativepg.md), [ADR-007](decisions/ADR-007-longhorn.md)) **Rationale:** Identity data and photo metadata are irreplaceable; workflow execution history is not. **Implementation:**

| Application   | StorageClass              |
| ------------- | ------------------------- |
| Authentik     | `longhorn` (3 replicas)   |
| Immich        | `longhorn` (3 replicas)   |
| Paperless-ngx | `longhorn` (3 replicas)   |
| n8n           | `longhorn-single-replica` |

- Default to `longhorn` (3 replicas) when in doubt
- `longhorn-single-replica` is only for data you would delete without hesitation if you needed the space

**Tags:** database, storage, kubernetes

______________________________________________________________________

**Rule DB-04: Deploy a CNPG `Pooler` (PgBouncer) for applications with many short-lived connections.** **Source:** ([ADR-006](decisions/ADR-006-cloudnativepg.md)) **Rationale:** Applications like Authentik and n8n open many short-lived connections; without pooling, connection exhaustion is a real failure mode. **Implementation:**

- `Pooler` CRD is managed by the same CNPG operator — no additional deployment
- Enable for: Authentik, n8n; evaluate for other apps on a per-connection-pattern basis
- Application connection string must point at the `Pooler` service, not the primary `Cluster` service

**Tags:** database, kubernetes

______________________________________________________________________

### [ADR-007](decisions/ADR-007-longhorn.md) — Longhorn Storage

______________________________________________________________________

**Rule STR-01: Use `longhorn` (3 replicas) for irreplaceable data; use `longhorn-single-replica` for ephemeral or reproducible data.** **Source:** ([ADR-007](decisions/ADR-007-longhorn.md)) **Rationale:** A single StorageClass forces over-replicating ephemeral data or under-protecting irreplaceable data; the two-class strategy solves both. **Implementation:**

- `longhorn` parameters: `numberOfReplicas: "3"` (default StorageClass)
- `longhorn-single-replica` parameters: `numberOfReplicas: "1"`, `dataLocality: "disabled"`
- Ephemeral class covers: Prometheus, Loki, Grafana, Alertmanager, Redis caches
- When in doubt, default to `longhorn`

**Tags:** storage, kubernetes

______________________________________________________________________

**Rule STR-02: Mount NFS-backed PVCs via the NFS CSI driver for shared filesystem workloads.** **Source:** ([ADR-007](decisions/ADR-007-longhorn.md), [ADR-020](decisions/ADR-020-storage-tier-strategy.md)) **Rationale:** Longhorn volumes are block devices and do not support simultaneous ReadWriteMany access; photo libraries and media files need shared filesystem semantics. **Implementation:**

- NFS CSI driver (`csi-driver-nfs`) deployed as an ArgoCD Application
- Two StorageClasses: `nfs-tier1` (Tier 1 btrfs RAID 1) and `nfs-tier2` (Tier 2 mergerfs)
- Both with `reclaimPolicy: Retain` — a `kubectl delete pvc` must not silently delete user data

**Tags:** storage, kubernetes, networking

______________________________________________________________________

### [ADR-008](decisions/ADR-008-authentik.md) — Authentik Identity Provider

______________________________________________________________________

**Rule AUTH-01: Every service must sit behind the Authentik identity perimeter.** **Source:** ([ADR-008](decisions/ADR-008-authentik.md)) **Rationale:** Per-app credential sprawl is a security risk; centralising authentication enables uniform MFA enforcement and single-operation access revocation. **Implementation:**

- Apps with native OIDC: configure Authentik provider and application via OpenTofu `goauthentik/authentik` provider
- Apps without SSO: add `ExtensionRef` forward auth filter to their `HTTPRoute` (see NET-03)
- No service is exposed via the Gateway without either OIDC or forward auth configured

**Tags:** security, authentication

______________________________________________________________________

**Rule AUTH-02: Manage all Authentik configuration via the OpenTofu provider, not the UI.** **Source:** ([ADR-008](decisions/ADR-008-authentik.md)) **Rationale:** UI changes are not version-controlled, not reproducible, and cannot be reviewed in a pull request. **Implementation:**

- Provider: `goauthentik/authentik` under `infrastructure/units/public/authentik/`
- Reusable pattern: catalog module at `infrastructure/catalogs/public/authentik-app/` — instantiate once per app
- Adding an application: `terragrunt apply` only; UI changes are forbidden in normal operation

**Tags:** iac, security, authentication

______________________________________________________________________

**Rule AUTH-03: The Authentik CNPG cluster uses `longhorn` (3 replicas) and Barman backup from day one.** **Source:** ([ADR-008](decisions/ADR-008-authentik.md)) **Rationale:** MFA state and OIDC client configs are irreplaceable; losing the Authentik database means re-enrolling every user and rebuilding every integration. **Implementation:**

- StorageClass: `longhorn` (3 replicas) — never `longhorn-single-replica`
- Barman WAL archiving to Garage S3 configured at cluster creation (see DB-02)
- Redis (session cache): `longhorn-single-replica` is acceptable — it is reproducible

**Tags:** database, storage, security, authentication

______________________________________________________________________

### [ADR-009](decisions/ADR-009-sops.md) — SOPS + age Secrets

______________________________________________________________________

**Rule SEC-01: Encrypt all secrets with SOPS + age before committing to git.** **Source:** ([ADR-009](decisions/ADR-009-sops.md)) **Rationale:** Any plaintext credential reachable by `git log` is permanently compromised after a push to a public remote. **Implementation:**

- SOPS config: `.sops.yaml` at repo root maps path patterns to age public keys
- Naming convention: `values.secret.yaml` (Helm), `*.secret.tfvars` (OpenTofu), whole-file for Ansible `host_vars/`
- gitleaks pre-commit hook blocks commits matching known secret formats; suppressions go in `.gitleaks.toml`

**Tags:** security, secrets

______________________________________________________________________

**Rule SEC-02: Never commit `talosconfig` or Talos `secrets.yaml` to git.** **Source:** ([ADR-009](decisions/ADR-009-sops.md)) **Rationale:** A compromised `talosconfig` gives full API access to Talos nodes including the ability to wipe them. **Implementation:**

- Both files are stored in a password manager; management documented in `docs/runbooks/cluster-rebuild.md`
- `.gitignore` must include `talosconfig` and `secrets.yaml` globally
- TODO: add a gitleaks rule matching Talos secret file patterns

**Tags:** security, kubernetes, secrets

______________________________________________________________________

**Rule SEC-03: CI runners must use a dedicated age key pair, not the developer key.** **Source:** ([ADR-009](decisions/ADR-009-sops.md)) **Rationale:** A compromised runner key can then be removed by rotating only that key, without having to re-encrypt every secret in the repository. **Implementation:**

- Dedicated runner age public key added as a recipient in the relevant SOPS creation rules in `.sops.yaml`
- Runner key stored as a Gitea Actions secret, not committed to the repo
- On runner compromise: remove runner key from `.sops.yaml`, re-encrypt affected files, rotate all secrets decrypted by that runner

**Tags:** security, ci, secrets

______________________________________________________________________

**Rule SEC-04: Use X25519 age keys until Terragrunt bug #5759 is resolved; migrate to ML-KEM post-quantum keys after.** **Source:** ([ADR-009](decisions/ADR-009-sops.md)) **Rationale:** PQ keys are the intended end state; the interim classical keys must be rotated at migration time to close historical ciphertext exposure. **Implementation:**

- Current state: standard X25519 age keys only
- Migration trigger: resolution of https://github.com/gruntwork-io/terragrunt/issues/5759
- Migration steps: generate PQ key pair → update `.sops.yaml` → `sops --rotate --in-place` all files → rotate all stored credentials → revoke old key

**Tags:** security, secrets

______________________________________________________________________

### [ADR-010](decisions/ADR-010-garage.md) — Garage S3

______________________________________________________________________

**Rule OBJ-01: Run Garage as a Proxmox LXC, not inside Kubernetes.** **Source:** ([ADR-010](decisions/ADR-010-garage.md)) **Rationale:** Garage must be available before OpenTofu can provision the cluster; hosting it inside Kubernetes creates a circular bootstrap dependency. **Implementation:**

- Garage LXC provisioned in Phase 0.9, before any OpenTofu unit migrates state
- Garage LXC is a hard dependency: its own bootstrap uses local state or a separately maintained state file
- Garage is monitored and backed up as part of the LXC operational runbook

**Tags:** storage, infrastructure, bootstrap

______________________________________________________________________

**Rule OBJ-02: Compensate for missing Garage bucket versioning with periodic rclone snapshots.** **Source:** ([ADR-010](decisions/ADR-010-garage.md), [ADR-015](decisions/ADR-015-disaster-recovery.md)) **Rationale:** Garage does not support bucket versioning; an overwritten or deleted Velero backup is not recoverable from Garage itself. **Implementation:**

- `rclone sync` of the Garage data directory to a separate location on a documented schedule
- Snapshot schedule and destination documented in the Garage runbook
- TODO: define snapshot frequency and retention policy

**Tags:** storage, backup

______________________________________________________________________

### [ADR-011](decisions/ADR-011-observability.md) — Observability

______________________________________________________________________

**Rule OBS-01: Deploy the full three-signal stack: kube-prometheus-stack, Loki, Grafana Tempo, and OTel Operator.** **Source:** ([ADR-011](decisions/ADR-011-observability.md)) **Rationale:** Metrics, logs, and traces in a single Grafana interface with time-based correlation reduces the mean time to diagnose an incident. **Implementation:**

- Deployed as ArgoCD Applications under `kubernetes/infrastructure/observability/`
- OTel Operator: DaemonSet mode for node-level collection; Deployment mode for receiving traces
- Tempo deployed now even without application instrumentation, so no retrofit is needed when tracing begins

**Tags:** observability, kubernetes

______________________________________________________________________

**Rule OBS-02: All observability PVCs use `longhorn-single-replica`.** **Source:** ([ADR-011](decisions/ADR-011-observability.md)) **Rationale:** Observability data is reproducible; scraping restores Prometheus within minutes, logs can be re-shipped, dashboards are in git. **Implementation:**

- StorageClass `longhorn-single-replica` on: Prometheus PVC, Loki PVC, Tempo PVC, Grafana PVC, Alertmanager PVC
- Prometheus retention: 30 days
- Exception: signal-cli-rest-api registration PVC uses `longhorn` (3 replicas) — see SEC-[ADR-012](decisions/ADR-012-alerting.md)

**Tags:** observability, storage, kubernetes

______________________________________________________________________

**Rule OBS-03: Integrate Grafana with Authentik via native OIDC (`auth.generic_oauth`), not forward auth.** **Source:** ([ADR-011](decisions/ADR-011-observability.md)) **Rationale:** Forward auth loses role mapping and group sync; native OIDC preserves them. **Implementation:**

- Config key: `auth.generic_oauth` in Grafana Helm values
- Values file: `kubernetes/infrastructure/observability/grafana/values.secret.yaml` (SOPS-encrypted)
- Keep `auth.generic_oauth` values in sync with the Authentik application config — drift breaks Grafana login

**Tags:** observability, security, authentication

______________________________________________________________________

**Rule OBS-04: Scrape Talos node metrics via `ScrapeConfig` with explicit static targets.** **Source:** ([ADR-011](decisions/ADR-011-observability.md)) **Rationale:** Talos node metrics are not auto-discovered by kube-prometheus-stack; they require explicit static target config and a Cilium NetworkPolicy permit rule. **Implementation:**

- Resource type: `ScrapeConfig` (prometheus-operator v1alpha1)
- Target port: `11234` on each node IP
- Require a `CiliumNetworkPolicy` allow rule in the `monitoring` namespace permitting ingress from the Prometheus pod to port `11234` on node IPs

**Tags:** observability, networking, kubernetes

______________________________________________________________________

### [ADR-012](decisions/ADR-012-alerting.md) — Alerting

______________________________________________________________________

**Rule ALT-01: Route all Alertmanager alerts to signal-cli-rest-api via `webhook_configs`.** **Source:** ([ADR-012](decisions/ADR-012-alerting.md)) **Rationale:** Signal provides E2E-encrypted push notifications with no intermediate SaaS dependency on the alert path beyond Signal's own infrastructure. **Implementation:**

- Alertmanager config key: `webhook_configs[].url: 'http://signal-cli-rest-api.observability.svc:8080/v2/send'`
- `send_resolved: true` on all receivers
- Group config: `group_wait: 30s`, `group_interval: 5m`, `repeat_interval: 4h`

**Tags:** observability, alerting

______________________________________________________________________

**Rule ALT-02: Store signal-cli-rest-api registration data on a `longhorn` (3-replica) PVC.** **Source:** ([ADR-012](decisions/ADR-012-alerting.md)) **Rationale:** Losing the registration PVC requires a new SMS verification code, which cannot be automated and creates a manual recovery step. **Implementation:**

- StorageClass: `longhorn` (3 replicas) — the only observability component that must not use `longhorn-single-replica`
- One-time registration: `kubectl exec` into the container, documented in Phase 6 runbook
- TODO: document recovery procedure if PVC is lost

**Tags:** observability, alerting, storage

______________________________________________________________________

### [ADR-013](decisions/ADR-013-cilium-network-policy.md) — Cilium NetworkPolicy & Trivy

______________________________________________________________________

**Rule SEC-05: Apply a default-deny `CiliumNetworkPolicy` to every namespace at creation time.** **Source:** ([ADR-013](decisions/ADR-013-cilium-network-policy.md)) **Rationale:** Applying default-deny retroactively means discovering undocumented connections by breaking them; applying at creation forces explicit connectivity declarations from the start. **Implementation:**

- Template (apply to every new namespace):

  ```yaml
  apiVersion: cilium.io/v2kind: CiliumNetworkPolicymetadata:  name: default-deny  namespace: <app-namespace>spec:  endpointSelector: {}  ingress:    - {}  egress:    - toEndpoints:        - matchLabels:            io.kubernetes.pod.namespace: kube-system            k8s-app: kube-dns      toPorts:        - ports:            - port: "53"              protocol: UDP
  ```

- Workload-specific allow rules are deployed as separate `CiliumNetworkPolicy` resources alongside the workload manifests

- Phase 8 is a dedicated audit-and-tighten pass for cross-namespace paths

**Tags:** security, networking, kubernetes

______________________________________________________________________

**Rule SEC-06: Use `CiliumNetworkPolicy` CRDs, not standard `networking.k8s.io/v1 NetworkPolicy`.** **Source:** ([ADR-013](decisions/ADR-013-cilium-network-policy.md)) **Rationale:** Standard NetworkPolicy is L3/L4 only; Cilium CRDs add L7 HTTP rules, DNS-name-based egress, and Hubble integration for diagnosing drops. **Implementation:**

- `apiVersion: cilium.io/v2` on all network policy resources
- Hubble must be enabled to surface policy drops: `helm values cilium | grep hubble.enabled` must be `true`
- Never mix `networking.k8s.io/v1 NetworkPolicy` and `CiliumNetworkPolicy` in the same namespace

**Tags:** security, networking, kubernetes

______________________________________________________________________

**Rule SEC-07: Deploy Trivy Operator for continuous in-cluster CVE scanning.** **Source:** ([ADR-013](decisions/ADR-013-cilium-network-policy.md)) **Rationale:** Renovate is proactive and git-aware but does not scan what is actually running; Trivy catches zero-days and newly published CVEs in already-deployed images. **Implementation:**

- Trivy Operator deployed as ArgoCD Application; `ServiceMonitor` enabled for Prometheus scraping
- Alert threshold: critical severity CVEs only in Alertmanager; medium/low surfaced in Grafana dashboards for periodic review
- Trivy requires an explicit outbound CiliumNetworkPolicy allow rule to GitHub releases for daily vulnerability database updates

**Tags:** security, kubernetes, observability

______________________________________________________________________

### [ADR-014](decisions/ADR-014-kyverno.md) — Kyverno Policy Engine

______________________________________________________________________

**Rule POL-01: Roll out all Kyverno policies in Audit mode before switching to Enforce.** **Source:** ([ADR-014](decisions/ADR-014-kyverno.md)) **Rationale:** Enabling enforcement on a non-compliant cluster immediately breaks workloads; the Audit phase produces a concrete remediation trail. **Implementation:**

- Sequence: deploy Kyverno in Audit → resolve all violations → switch to Enforce
- `failurePolicy: Ignore` for the initial rollout; revisit after Kyverno stability is established
- Kyverno namespace must be excluded from its own policies — configure exclusion at deploy time

**Tags:** security, kubernetes, process

______________________________________________________________________

**Rule POL-02: Require CPU and memory limits on all containers.** **Source:** ([ADR-014](decisions/ADR-014-kyverno.md)) **Rationale:** A misbehaving workload without limits can starve the node; this is a prerequisite for `longhorn-single-replica` observability workloads to be safe. **Implementation:**

- Kyverno `ClusterPolicy` with `validate` rule requiring `resources.limits.cpu` and `resources.limits.memory`
- Mutating policy to inject defaults at admission in development namespaces
- CI check: `kube-score` flags missing limits before the cluster sees the manifest

**Tags:** security, kubernetes, resource-management

______________________________________________________________________

**Rule POL-03: Prohibit `latest` and mutable image tags.** **Source:** ([ADR-014](decisions/ADR-014-kyverno.md)) **Rationale:** Mutable tags make it impossible to know what is actually running or to reproduce a deployment. **Implementation:**

- Disallowed tags: `:latest`, `:main`, `:stable`, `:edge` — configured as a list in the Kyverno policy
- All pinned tags managed by Renovate (see DEP-01) via automated PRs
- Kyverno validates; Renovate keeps pinned tags current

**Tags:** security, kubernetes, dependencies

______________________________________________________________________

**Rule POL-04: Restrict image sources to approved registries.** **Source:** ([ADR-014](decisions/ADR-014-kyverno.md)) **Rationale:** Images from arbitrary registries are a supply chain attack vector. **Implementation:**

- Approved registries: Docker Hub official images, GHCR (`ghcr.io`), Quay.io (`quay.io`)
- Kyverno `ClusterPolicy` with `validate` rule checking `image` field against the approved list
- New registry requires a deliberate policy update and ADR note

**Tags:** security, kubernetes

______________________________________________________________________

**Rule POL-05: Reject privileged containers unless a named `PolicyException` is committed to git.** **Source:** ([ADR-014](decisions/ADR-014-kyverno.md)) **Rationale:** Privileged containers have effective root access to the host; every exception must be explicit and auditable. **Implementation:**

- Current approved exceptions (each has a `PolicyException` resource with rationale comment):
  - Longhorn (block device management)
  - Cilium (eBPF program loading)
  - NFS CSI driver (kernel NFS mounts)
- `PolicyException` resource committed under `kubernetes/infrastructure/kyverno/exceptions/`
- No silent carve-outs via namespace label overrides

**Tags:** security, kubernetes

______________________________________________________________________

### [ADR-015](decisions/ADR-015-disaster-recovery.md) — Disaster Recovery

______________________________________________________________________

**Rule DR-01: Use three independent backup layers: Velero, etcd snapshot, and CNPG Barman.** **Source:** ([ADR-015](decisions/ADR-015-disaster-recovery.md)) **Rationale:** No single tool covers all three state planes (Kubernetes API resources, control plane, application data); each layer targets a different failure mode. **Implementation:**

- Velero: daily, 7-day retention, writes to Garage S3
- `talosctl etcd snapshot`: daily, 7 snapshots retained, uploads to Garage S3
- CNPG Barman: continuous WAL archiving + periodic base backups per Cluster
- Full restore sequence: documented in `docs/runbooks/cluster-rebuild.md`

**Tags:** backup, kubernetes, database

______________________________________________________________________

**Rule DR-02: Always include the cert-manager namespace in Velero backups.** **Source:** ([ADR-015](decisions/ADR-015-disaster-recovery.md)) **Rationale:** The Let's Encrypt ACME account registration secret is never stored in git; losing it during a rebuild stalls TLS issuance for up to one week if the wildcard rate limit has been hit. **Implementation:**

- Velero backup spec: explicitly include `cert-manager` namespace
- Velero backup spec: explicitly exclude `kube-system` (Talos and CoreDNS are reproducible from git)
- `cert-manager` must never appear on a Velero exclusion list

**Tags:** backup, tls, kubernetes

______________________________________________________________________

**Rule DR-03: Test Velero restore against a scratch cluster before treating backups as production.** **Source:** ([ADR-015](decisions/ADR-015-disaster-recovery.md)) **Rationale:** An untested backup is not a backup. **Implementation:**

- Phase 9 deliverable: restore test against an isolated cluster; RTO estimate updated after test
- Test must cover: CNPG Cluster restore triggering Barman WAL recovery automatically
- Restore sequence walk-through documented in `docs/runbooks/cluster-rebuild.md`

**Tags:** backup, process, kubernetes

______________________________________________________________________

### [ADR-016](decisions/ADR-016-ansible-for-proxmox-host-configuration.md) — Ansible

______________________________________________________________________

**Rule CFG-01: All Proxmox host configuration changes go through `ansible/`, never direct SSH.** **Source:** ([ADR-016](decisions/ADR-016-ansible-for-proxmox-host-configuration.md)) **Rationale:** Ad-hoc SSH changes are untracked, non-idempotent, and not reproducible — the failure mode [ADR-000](decisions/ADR-000-project-goals.md) explicitly targets. **Implementation:**

- Roles: `proxmox-base`, `fan-control`, `pve-exporter`, `custom-scripts`
- Main playbook: `ansible/bootstrap.yml` — safe to re-run at any time
- Verify playbook: `ansible/verify.yml` — checks state without changes; runs in CI on every PR touching `ansible/`

**Tags:** iac, configuration-management

______________________________________________________________________

**Rule CFG-02: Ansible owns the OS layer; OpenTofu owns the resource layer. Never let them overlap.** **Source:** ([ADR-016](decisions/ADR-016-ansible-for-proxmox-host-configuration.md)) **Rationale:** When both tools manage the same file or resource, neither is authoritative and the state is unpredictable. **Implementation:**

- Ansible scope: apt repositories, packages, sysctl, SSH hardening, fan control, pve-exporter, host-level scripts
- OpenTofu scope: VMs, LXCs, DNS records, object storage buckets, Kubernetes workloads
- Any new host-level concern goes into `ansible/`; any new Proxmox resource goes into `infrastructure/units/`

**Tags:** iac, configuration-management

______________________________________________________________________

### [ADR-017](decisions/ADR-017-infrastructure-diagramming-strategy.md) — Diagramming

______________________________________________________________________

**Rule DOC-01: Auto-generate OpenTofu diagrams via inframap on every merge touching `infrastructure/`.** **Source:** ([ADR-017](decisions/ADR-017-infrastructure-diagramming-strategy.md)) **Rationale:** Hand-maintained diagrams go stale after the first topology change; auto-generation from state ensures accuracy. **Implementation:**

- Command: `tofu state pull | inframap generate --tfstate | dot -Tsvg > docs/diagrams/terraform.svg`
- Requires self-hosted runner with Garage S3 network access
- Diagrams committed back by the pipeline with `[skip ci]` to avoid a loop

**Tags:** documentation, ci

______________________________________________________________________

**Rule DOC-02: Auto-generate Kubernetes workload diagrams via KubeDiagrams on every merge touching `kubernetes/`.** **Source:** ([ADR-017](decisions/ADR-017-infrastructure-diagramming-strategy.md)) **Rationale:** Live-cluster KubeDiagrams output diverging from the CI-generated diagram signals a GitOps violation. **Implementation:**

- Commands: `kubediagrams kubernetes/infrastructure/` and `kubediagrams kubernetes/apps/`
- No live cluster access needed in CI — runs from git manifests
- Divergence check: run `kubediagrams --from-cluster` manually and diff against CI output

**Tags:** documentation, ci, gitops

______________________________________________________________________

**Rule DOC-03: Update `docs/diagrams/architecture.md` (Mermaid) as part of the definition of done for any topology change.** **Source:** ([ADR-017](decisions/ADR-017-infrastructure-diagramming-strategy.md)) **Rationale:** The full architecture diagram spans layers that no tool can auto-generate; it must be hand-maintained or it goes stale. **Implementation:**

- Triggers for update: new LXC, new major service, changed network path, new storage tier
- Mermaid renders natively in Gitea and Codeberg — no build step needed
- Checklist item on topology-change PRs: "architecture.md updated?"

**Tags:** documentation, process

______________________________________________________________________

### [ADR-018](decisions/ADR-018-tailscale.md) — Tailscale

______________________________________________________________________

**Rule VPN-01: Replace the Tailscale default allow-all ACL policy immediately after provisioning.** **Source:** ([ADR-018](decisions/ADR-018-tailscale.md)) **Rationale:** The default policy allows all tailnet members to reach all services; a homelab with multiple users must restrict by role. **Implementation:**

- Owner: full access to all services, SSH, and Proxmox management port
- Additional users: HTTP/HTTPS to internal services only; SSH and Proxmox port are owner-only
- Sanitised ACL template committed to the public Codeberg mirror

**Tags:** security, networking, vpn

______________________________________________________________________

**Rule VPN-02: Register both AdGuard LXC IPs as restricted nameservers in Tailscale MagicDNS.** **Source:** ([ADR-018](decisions/ADR-018-tailscale.md), [ADR-019](decisions/ADR-019-adguard-ha-setup.md)) **Rationale:** A single DNS resolver in MagicDNS creates a Tailscale-specific single point of failure for `*.yourdomain.internal` resolution. **Implementation:**

- MagicDNS config: both AdGuard IPs registered as restricted nameservers scoped to `yourdomain.internal`
- This extends AdGuard HA failover (see [ADR-019](decisions/ADR-019-adguard-ha-setup.md)) to Tailscale-connected devices
- Verify: from a Tailscale-connected device, `dig @<tailscale-ip> grafana.yourdomain.internal` must resolve

**Tags:** networking, dns, vpn

______________________________________________________________________

### [ADR-019](decisions/ADR-019-adguard-ha-setup.md) — AdGuard HA

______________________________________________________________________

**Rule DNS-01: Run two AdGuard Home LXCs with `adguardhome-sync` pushing config from primary to replica every 5 minutes.** **Source:** ([ADR-019](decisions/ADR-019-adguard-ha-setup.md)) **Rationale:** A single AdGuard instance creates a DNS blackout on every maintenance or restart; AdGuard Home has no native HA mode. **Implementation:**

- `adguardhome-sync` cron: `*/5 * * * *` with `runOnStart: true` and `continueOnError: true`
- Credentials: SOPS-encrypted in `adguardhome-sync.yaml` on the primary LXC
- MikroTik DHCP server lists both IPs as DNS resolvers; clients fall back automatically

**Tags:** networking, dns, high-availability

______________________________________________________________________

**Rule DNS-02: All AdGuard config changes go through OpenTofu targeting the primary only.** **Source:** ([ADR-019](decisions/ADR-019-adguard-ha-setup.md)) **Rationale:** The replica is read-only and never a source of truth; changes applied directly to the replica are overwritten by the next sync cycle. **Implementation:**

- OpenTofu unit: `infrastructure/units/public/adguard/`
- Replica web UI is a passive canary: visible drift from the primary without explanation means the sync process has failed silently
- Never `terragrunt apply` against the replica unit

**Tags:** networking, dns, iac

______________________________________________________________________

### [ADR-020](decisions/ADR-020-storage-tier-strategy.md) — Storage Tiers

______________________________________________________________________

**Rule STR-03: Format Tier 1 drives (irreplaceable data) as native btrfs RAID 1 with no mdadm or LVM.** **Source:** ([ADR-020](decisions/ADR-020-storage-tier-strategy.md)) **Rationale:** mdadm RAID 1 does not verify both copies on every read; btrfs checksums every block and proactively repairs corruption during weekly scrubs. **Implementation:**

- btrfs RAID 1 profile for both data and metadata: `mkfs.btrfs -d raid1 -m raid1 /dev/sdX /dev/sdY`
- Weekly `btrfs scrub` followed by `duperemove` incremental deduplication
- Alertmanager alert on any `btrfs scrub status` error output

**Tags:** storage, data-integrity

______________________________________________________________________

**Rule STR-04: Pool Tier 2 drives (recreatable data) with mergerfs JBOD using `mfs` create policy.** **Source:** ([ADR-020](decisions/ADR-020-storage-tier-strategy.md)) **Rationale:** mergerfs JBOD limits failure blast radius to a single drive; btrfs RAID 0 would corrupt the entire pool on any single drive failure. **Implementation:**

- Each drive formatted individually: `mkfs.btrfs /dev/sdX` (single profile)
- mergerfs mount point: `/mnt/bulk` with create policy `mfs` and `minfreespace=50G`
- Adding a drive: format → mount → add to mergerfs source list → remount; no rebuild required

**Tags:** storage, data-integrity

______________________________________________________________________

**Rule STR-05: Set `reclaimPolicy: Retain` on all NFS StorageClasses.** **Source:** ([ADR-020](decisions/ADR-020-storage-tier-strategy.md)) **Rationale:** A `kubectl delete pvc` must never silently delete the photo library or the media archive. **Implementation:**

- `nfs-tier1` StorageClass: `reclaimPolicy: Retain`
- `nfs-tier2` StorageClass: `reclaimPolicy: Retain`
- Released PVs require explicit manual cleanup after confirming data is no longer needed

**Tags:** storage, kubernetes, data-integrity

______________________________________________________________________

**Rule STR-06: Run weekly `btrfs scrub` on all drives across both tiers.** **Source:** ([ADR-020](decisions/ADR-020-storage-tier-strategy.md)) **Rationale:** Spinning drives that sit mostly idle can return corrupted data without surfacing a read error; proactive scrubbing finds and repairs corruption before an application reads a corrupt file. **Implementation:**

- Tier 1: weekly scrub on the btrfs RAID 1 pool
- Tier 2: weekly scrub on each individual btrfs single drive
- `btrfs scrub status` output is the primary storage health signal; Alertmanager alert on any errors

**Tags:** storage, data-integrity

______________________________________________________________________

### [ADR-H](decisions/ADR-H-hardware-platform.md) — Hardware Platform

______________________________________________________________________

**Rule HW-01: Enable AMD EXPO in BIOS to run DDR5 at 6000MHz.** **Source:** ([ADR-H](decisions/ADR-H-hardware-platform.md)) **Rationale:** The JEDEC default (4800MHz) provides significantly less memory bandwidth; 6000MHz is what makes CPU-based LLM inference viable at useful token rates. **Implementation:**

- BIOS setting: enable EXPO profile (the 6000MHz CL36 kit)
- Verify post-boot: `dmidecode --type memory | grep Speed` must show 6000MT/s
- Without EXPO, LLM inference and Immich ML workloads are meaningfully slower

**Tags:** hardware

______________________________________________________________________

**Rule HW-02: Accept that there is no offsite backup for Tier 1 storage until Phase 15.** **Source:** ([ADR-H](decisions/ADR-H-hardware-platform.md), [ADR-020](decisions/ADR-020-storage-tier-strategy.md)) **Rationale:** btrfs RAID 1 covers single-drive failure only; simultaneous failure of both WD Red Plus drives, physical loss, or theft means permanent loss of the photo and document archive. **Implementation:**

- Known gap: explicitly deferred to Phase 15
- Current mitigation: btrfs RAID 1 covers single-drive failure
- Phase 15 deliverable: offsite backup destination and rclone/restic job for Tier 1 data

**Tags:** backup, hardware, data-integrity

______________________________________________________________________

## Conflicts & Exceptions

### Exception approval process

Any deviation from a rule in this rulebook requires:

1. **Owner sign-off.** The infrastructure owner must explicitly approve the exception.
2. **ADR note.** The exception must be documented in the relevant ADR's Consequences section or as an amendment, including: the rule being waived, the reason, and the expected duration.
3. **Time-bound or permanent classification.** Temporary exceptions (e.g., during a migration phase) must include a resolution trigger. Permanent exceptions must justify why the rule does not apply to that specific context.
4. **PR reference.** The exception PR must link to the ADR update.

### Known rule interactions to watch

- **STR-01 vs OBS-02:** The default StorageClass is `longhorn` (3 replicas), but observability PVCs must use `longhorn-single-replica`. Any observability PVC without an explicit `storageClassName` will silently use the 3-replica default — always set `storageClassName` explicitly.
- **POL-05 vs STR-01/SEC-05:** Longhorn and Cilium require privileged containers and broad host access to function. Their `PolicyException` resources are pre-approved; any change to those workloads must re-verify the exception still applies.
- **GIT-01 vs K8S-02:** The ArgoCD bootstrap is the only sanctioned use of imperative `helm upgrade --install`. Any other imperative step must be reviewed against K8S-02.
- **SEC-01 vs IaC-04:** SOPS-encrypted files are safe to publish. Verify `.sops.yaml` path patterns cover all new secret file locations before adding them to the public mirror.

### Conflict reporting

If a change satisfies one rule while violating another, open a discussion thread on the PR and tag it `conflict`. Do not merge until the conflict is resolved and the relevant ADRs are updated.

______________________________________________________________________

## ADRs That Could Not Be Converted Into Rules

None. All ADRs in this set contain a Decision section with actionable content. The following ADRs produced fewer rules than expected due to their primarily contextual or comparative nature — their key decisions are captured but their full reasoning is best read in the source ADR:

- **[ADR-001](decisions/ADR-001-kubernetes.md):** Most decision content folded into K8S-01/K8S-02; the detailed alternatives analysis (Nomad, k3s, Docker Swarm) is context, not rules.
- **[ADR-011](decisions/ADR-011-observability.md):** The managed service rejection (Datadog, Grafana Cloud) is rationale, not a rule; captured in OBS-01.
- **[ADR-014](decisions/ADR-014-kyverno.md):** The OPA Gatekeeper vs Kyverno comparison is context; the rules capture the outcomes.

______________________________________________________________________

## Changelog

| Version | Date       | Notes                                                                                                                             |
| ------- | ---------- | --------------------------------------------------------------------------------------------------------------------------------- |
| v1.0    | 2026-04-22 | Initial rulebook derived from [ADR-000](decisions/ADR-000-project-goals.md) through [ADR-H](decisions/ADR-H-hardware-platform.md) |
