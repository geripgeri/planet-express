# Infra Rulebook

**Version:** v1.0 **Purpose:** Actionable infrastructure rules derived from every ADR in this homelab. **How to use:** When you provision, code or review, check your change against every applicable rule. If you cannot follow a rule, use the Conflicts & Exceptions process below.

## Rules

### [ADR-000](decisions/ADR-000-project-goals.md): Project Goals & Principles

**Rule IaC-01: Express every infrastructure resource as code.** **Implementation:**

- No manual clicks in the Proxmox UI, no `kubectl apply` outside bootstrap; all changes go through OpenTofu, Ansible or ArgoCD
- Definition of done for any phase: a stranger clones the repo, follows the runbook and reproduces the result
- TODO: add a CI gate that fails if a resource in `infrastructure/` has no matching OpenTofu unit

**Rule IaC-02: Write ADRs at decision time, not after.** **Implementation:**

- The ADR is a required deliverable before merging any architectural change
- Known gaps and failed attempts must be documented explicitly, not omitted
- ADR format: `ADR-NNN-short-title.md` under `docs/decisions/`

**Rule IaC-03: Run two-tier CI on every PR.** **Implementation:**

- Tier 1 (static, hosted runners): `tofu validate`, `tofu fmt`, `yamllint`, `ansible-lint`
- Tier 2 (integration, self-hosted runner): Terratest Go tests against the real Proxmox API: provision, assert, destroy
- Integration tests are scoped to catalog modules only, never to production units

**Rule IaC-04: Publish selectively using `.gitattributes` export-ignore.** **Implementation:**

- `catalogs/public/` and `units/public/` → mirrored to GitHub and Codeberg
- `catalogs/private/` and `units/private/` → excluded via `.gitattributes` export-ignore with `git-filter-repo`
- Before each public push, check the mirror: `git archive HEAD | tar -t | grep private` should return empty

### [ADR-001](decisions/ADR-001-kubernetes.md): Kubernetes Platform

**Rule K8S-01: Use Talos Linux as the Kubernetes node OS.** **Implementation:**

- All node config changes go through `talosctl apply-config`, with machine config patches committed to git
- Never install packages or make runtime changes on a Talos node
- `talosconfig` and `secrets.yaml` are stored outside git (see [ADR-009](decisions/ADR-009-sops.md))

**Rule K8S-02: Never use `kubectl apply` in normal operations.** **Source:** also [ADR-003](decisions/ADR-003-argocd.md) **Implementation:**

- ArgoCD manages all workloads; changes go through git commits and ArgoCD sync
- Permitted exception: bootstrap operations (ArgoCD install, Cilium install) that must precede the GitOps loop, documented in `docs/runbooks/`
- Break-glass `kubectl apply` requires a follow-up git commit to reconcile state before the runbook closes

**Rule K8S-03: Run non-Kubernetes services as Proxmox LXCs or VMs.** **Implementation:**

- Services that must precede cluster bootstrap (Garage, AdGuard) run as LXCs
- Services with kernel-level needs (NFS server, fan control) run as LXCs managed by Ansible
- Kubernetes is not used where "the cluster is down" and "the service is down" should be independent events

### [ADR-002](decisions/ADR-002-opentofu-terragrunt.md): OpenTofu + Terragrunt

**Rule TF-01: Use OpenTofu, not Terraform.** **Implementation:**

- Binary: `tofu`, not `terraform`
- Lock files: `use_lockfile = true` in all backend configs (replaces DynamoDB locking)
- All provider references use the same registry paths, so no migration is needed from Terraform HCL

**Rule TF-02: Follow the catalog/stack/unit pattern via Terragrunt.** **Implementation:**

- Catalog modules live in `infrastructure/catalogs/`: pure HCL, no live values, safe to publish
- Units live in `infrastructure/units/`: one `terragrunt.hcl` per resource, one state file per unit
- Stacks live in `infrastructure/stacks/`: declare dependency order and wire outputs between units via `terragrunt.stack.hcl`

**Rule TF-03: Remote state in Garage S3 from the first provisioned resource.** **Source:** also [ADR-010](decisions/ADR-010-garage.md) **Implementation:**

- Backend config is defined once in `root.hcl` and inherited by all units
- `use_lockfile = true` replaces DynamoDB; Garage supports the required `PutObject`/`DeleteObject` ops
- Incremental migration: move each unit to remote state, verify it before the next

### [ADR-003](decisions/ADR-003-argocd.md): ArgoCD GitOps

**Rule GIT-01: Bootstrap ArgoCD once via OpenTofu `helm_release`, then make it self-managing.** **Implementation:**

- Bootstrap: OpenTofu `helm_release` installs the ArgoCD chart; chart-rendered resources stay in OpenTofu state
- Self-management: an Application owns only `kubernetes/infrastructure/argocd/` (config-only manifests). Merge to main is the approval gate, and ArgoCD reconciles after it
- Break-glass runbook: `docs/runbooks/argocd-breakglass.md`, a required deliverable before [Phase 1](../README.md#phases) is complete

**Rule GIT-02: Use the App of Apps pattern for workload discovery.** **Implementation:**

- The root Application manages all child Applications by directory under `kubernetes/apps/` and `kubernetes/infrastructure/`
- ApplicationSet controller (`argocd-applicationset`) must be enabled in the ArgoCD Helm values
- Adding a new service: create the directory, commit; the ApplicationSet picks it up on the next sync
- TODO: move thin Application CRs from `kubernetes/infrastructure/private/apps/` to a public path once the internal Gitea `repoURL` can be a ksops-encrypted value ([ADR-021](decisions/ADR-021-public-mirror-privacy-partitioning.md) September 2026 amendment)

**Rule GIT-03: Do not expose the ArgoCD UI until Authentik OIDC is live.** **Implementation:**

- During Phases 1–5: access via `kubectl port-forward svc/argocd-server -n argocd 8080:443`
- Admin password: SOPS-encrypted immediately after bootstrap (see [ADR-009](decisions/ADR-009-sops.md))
- Gateway API `HTTPRoute` for ArgoCD is only created in Phase 5/6, when Authentik OIDC is configured

### [ADR-004](decisions/ADR-004-renovate.md): Renovate

**Rule DEP-01: Deploy Renovate as a nightly scheduled Gitea Actions workflow on a self-hosted runner.** **Implementation:**

- Schedule: `cron: '0 3 * * *'` plus `workflow_dispatch` for on-demand runs
- Config file: `renovate.json` at repo root with `argocd`, `helm-values` and `terraform` managers enabled
- Runner: self-hosted, the same runner registered for integration tests

**Rule DEP-02: Automerge minor and patch updates; require manual review for major bumps.** **Implementation:**

- `renovate.json` extends `":automergeMinor"` and `"config:recommended"`
- Major bumps open a PR and are blocked from automerge; changelog review is expected before merge
- Cilium chart bumps (Gateway API behaviour can change between minor versions) should include changelog review even for minor updates

**Rule DEP-03: Keep Dependabot active on the public GitHub/Codeberg mirror.** **Implementation:**

- No `dependabot.yaml` configuration needed for public repos. GitHub enables it automatically
- Dependabot and Renovate do not conflict: Renovate bumps proactively, Dependabot flags security issues reactively
- Do not disable Dependabot on the mirror to "keep PRs clean"

### [ADR-005](decisions/ADR-005-cilium-gateway-api.md): Cilium Gateway API

**Rule NET-01: Use Cilium's built-in Gateway API controller; deploy no separate ingress controller.** **Rationale:** ingress-nginx reached EOL in March 2026, the `Ingress` API is frozen, and Cilium already handles L3/L4, so a second L7 proxy duplicates without adding value. **Implementation:**

- No `kind: Ingress` resources anywhere in the cluster
- All HTTP/HTTPS routing uses `GatewayClass`, `Gateway` and `HTTPRoute` resources
- Verify Cilium Gateway API support: `helm show values cilium/cilium | grep gatewayAPI.enabled` must be `true`

**Rule NET-02: Terminate TLS at a single shared Gateway using a wildcard cert.** **Implementation:**

- Shared Gateway lives in `kube-system`; wildcard cert `*.yourdomain.internal` provisioned by cert-manager via DNS-01
- Application `HTTPRoute` specifies only `hostname` and `backendRef`, no TLS stanza
- cert-manager `Certificate` resource committed to `kubernetes/infrastructure/cert-manager/`

**Rule NET-03: Use Authentik `ExtensionRef` forward auth for services without native OIDC; use native OIDC for services that support it.** **Source:** also [ADR-008](decisions/ADR-008-authentik.md) **Implementation:**

- Native OIDC apps (Grafana, ArgoCD, Proxmox): configure `auth.generic_oauth` or equivalent directly
- Non-OIDC apps: add `ExtensionRef` filter on `HTTPRoute` pointing at the Authentik embedded outpost
- Verify `ExtensionRef` filter syntax against the deployed Cilium version: syntax changed between 1.13 and 1.14

**Rule NET-04: Keep the pinned Gateway API CRD bundle at or above the version the deployed Cilium chart requires.** **Rationale:** The operator skips its whole Gateway API control plane when a required CRD or CRD version is missing. Every hostname on the shared Gateway then resets, while existing routes keep their last written status and the Gateway keeps a stale `Programmed` condition, so a cluster-wide outage reads as a per-route fault. Cilium 1.20.2 needs Gateway API v1.5.0 or newer (`tlsroutes` and `referencegrants` at `v1`, plus `backendtlspolicies`). **Implementation:**

- Bundle pinned in `kubernetes/infrastructure/private/network/gateway-api-crds.yaml`, applied by ArgoCD; the Cilium chart does not install it
- Before a chart upgrade, read the operator's requirement: `kubectl -n kube-system logs deploy/cilium-operator --tail=200 | grep -i "Required GatewayAPI"`
- After the upgrade, the same command must return nothing, and `kubectl get httproute -A -o wide` must show parent and address columns
- `operator.rollOutPods = true` keeps the operator rolling on `cilium-config` changes; the precheck runs at startup only, so a CRD fix needs an operator rollout to take effect
- Treat a route with an empty status as this failure first, not as a route or DNS problem

### [ADR-006](decisions/ADR-006-cloudnativepg.md): CloudNativePG

**Rule DB-01: Every application requiring Postgres gets its own dedicated CNPG `Cluster` resource.** **Implementation:**

- No shared Postgres, no ad-hoc `kubectl exec psql`
- Each `Cluster` manifest lives under `kubernetes/apps/<app-name>/`
- The `Cluster` resource is committed to git before the application is deployed

**Rule DB-02: Configure Barman WAL archiving on every CNPG Cluster at creation time.** **Source:** also [ADR-015](decisions/ADR-015-disaster-recovery.md) **Implementation:**

- `backup.barmanObjectStore` must be present in every `Cluster` manifest
- Target: Garage S3 bucket provisioned in Phase 0.9 (see [ADR-010](decisions/ADR-010-garage.md))
- Enforced as a pattern in the `k8s-app` catalog module. TODO: add a Kyverno policy rejecting `Cluster` resources missing `backup.barmanObjectStore`

**Rule DB-03: Assign StorageClass to CNPG Clusters based on recoverability.** **Source:** also [ADR-007](decisions/ADR-007-longhorn.md) **Implementation:**

| Application   | StorageClass              |
| ------------- | ------------------------- |
| Authentik     | `longhorn` (3 replicas)   |
| Immich        | `longhorn` (3 replicas)   |
| Paperless-ngx | `longhorn` (3 replicas)   |
| n8n           | `longhorn-single-replica` |

- Default to `longhorn` (3 replicas) when in doubt
- `longhorn-single-replica` is only for data you would delete without hesitation if you needed the space

**Rule DB-04: Deploy a CNPG `Pooler` (PgBouncer) for applications with many short-lived connections.** **Implementation:**

- `Pooler` CRD is managed by the same CNPG operator, so no additional deployment
- Enable for: Authentik, n8n; evaluate for other apps on a per-connection-pattern basis
- Application connection string must point at the `Pooler` service, not the primary `Cluster` service

### [ADR-007](decisions/ADR-007-longhorn.md): Longhorn Storage

**Rule STR-01: Use `longhorn` (3 replicas) for irreplaceable data; use `longhorn-single-replica` for ephemeral or reproducible data.** **Implementation:**

- `longhorn` parameters: `numberOfReplicas: "3"` (default StorageClass)
- `longhorn-single-replica` parameters: `numberOfReplicas: "1"`, `dataLocality: "disabled"`
- Ephemeral class covers: Prometheus, Loki, Grafana, Alertmanager, Redis caches
- When in doubt, default to `longhorn`

**Rule STR-02: Mount NFS-backed PVCs via the NFS CSI driver for shared filesystem workloads.** **Source:** also [ADR-020](decisions/ADR-020-storage-tier-strategy.md) **Implementation:**

- NFS CSI driver (`csi-driver-nfs`) deployed as an ArgoCD Application
- Two StorageClasses: `nfs-tier1` (Tier 1 btrfs RAID 1) and `nfs-tier2` (Tier 2 mergerfs)
- Both with `reclaimPolicy: Retain`: a `kubectl delete pvc` must not silently delete user data

### [ADR-008](decisions/ADR-008-authentik.md): Authentik Identity Provider

**Rule AUTH-01: Every service must sit behind the Authentik identity perimeter.** **Implementation:**

- Apps with native OIDC: configure the Authentik provider and application through the OpenTofu `goauthentik/authentik` provider
- Apps without SSO: add an `ExtensionRef` forward auth filter to their `HTTPRoute` (see NET-03)
- No service is exposed via the Gateway without either OIDC or forward auth configured

**Rule AUTH-02: Manage all Authentik configuration via the OpenTofu provider, not the UI.** **Implementation:**

- Provider: `goauthentik/authentik` under `infrastructure/units/public/authentik/`
- Reusable pattern: catalog module at `infrastructure/catalogs/public/authentik-app/`, instantiate once per app
- Adding an application: `terragrunt apply` only; UI changes are forbidden in normal operation

**Rule AUTH-03: The Authentik CNPG cluster uses `longhorn` (3 replicas) and Barman backup from day one.** **Implementation:**

- StorageClass: `longhorn` (3 replicas), never `longhorn-single-replica`
- Barman WAL archiving to Garage S3 configured at cluster creation (see DB-02)
- Redis (session cache): `longhorn-single-replica` is acceptable because it is reproducible

### [ADR-009](decisions/ADR-009-sops.md): SOPS + age Secrets

**Rule SEC-01: Encrypt all secrets with SOPS + age before committing to git.** **Implementation:**

- SOPS config: `.sops.yaml` at repo root maps path patterns to age public keys
- Naming convention: `values.secret.yaml` (Helm), `*.secret.tfvars` (OpenTofu), whole-file for Ansible `host_vars/`
- Kubernetes `Secret` manifests under `kubernetes/` are whole-file SOPS ciphertext, decrypted only in the ArgoCD repo-server by the ksops plugin ([ADR-021](decisions/ADR-021-public-mirror-privacy-partitioning.md), September 2026 amendment)
- The gitleaks pre-commit hook blocks commits matching known secret formats; suppressions go in `.gitleaks.toml`

**Rule SEC-02: Never commit `talosconfig` or Talos `secrets.yaml` to git.** **Implementation:**

- Both files sit in a password manager, and the management flow is documented in `docs/runbooks/cluster-rebuild.md`
- `.gitignore` must include `talosconfig` and `secrets.yaml` globally
- gitleaks custom rules `talosconfig-file`, `talos-kubeconfig-keydata` and `talos-machine-secrets-yaml` in `.gitleaks.toml` block Talos credential patterns, including renamed or dated copies

**Rule SEC-03: CI runners must use a dedicated age key pair, not the developer key.** **Rationale:** A compromised runner key is removed by rotating only that key, with no re-encryption of every secret in the repository. **Implementation:**

- The dedicated runner age public key is a recipient in the relevant SOPS creation rules in `.sops.yaml`
- Runner key stored as a Gitea Actions secret, not committed to the repo
- On runner compromise: remove the key from `.sops.yaml`, re-encrypt affected files, rotate every secret that runner decrypted

**Rule SEC-04: Use ML-KEM post-quantum age keys for all SOPS encryption.** **Rationale:** Terragrunt bug #5759 blocked PQ recipients and is now resolved, so ML-KEM keys are the standard and X25519 keys are revoked. Historical commits keep X25519-wrapped ciphertexts, but the rotation at migration time means any decrypted historical ciphertext yields a dead credential. **Implementation:**

- Generate keys with `age-keygen -pq`
- Public keys reference `age1pq…` recipients in `.sops.yaml`
- Private key stored in password manager; no X25519 fallback

### [ADR-010](decisions/ADR-010-garage.md): Garage S3

**Rule OBJ-01: Run Garage as a Proxmox LXC, not inside Kubernetes.** **Implementation:**

- Garage LXC provisioned in Phase 0.9, before any OpenTofu unit migrates state
- Garage LXC is a hard dependency: its own bootstrap uses local state or a separately maintained state file
- The `garage-lxc` unit (`infrastructure/units/public/proxmox/garage-lxc/`) provisions it via the reusable `lxc` module (`infrastructure/catalogs/public/lxc/`); its static IP lives in `secrets.yaml` under `network_config.garage_lxc` because LXC resources expose no provider-discovered address
- The `garage` Ansible role (`ansible/roles/garage/`), applied by `bootstrap.yaml` to the `lxc` inventory group, installs and configures the guest; `docs/runbooks/garage-lxc-setup.md` covers vault creation, the one-time cluster layout bootstrap and the state bucket/key provisioning flow
- The single `garage/tofu-state` unit (stack `infrastructure/stacks/public/garage/`) provisions the state bucket and access key through the `schwitzd/garage` provider; `garage.admin_token` in `secrets.yaml` is the shared admin credential
- Garage is monitored and backed up as part of the LXC operational runbook

**Rule OBJ-02: Compensate for missing Garage bucket versioning with periodic rclone snapshots.** **Source:** also [ADR-015](decisions/ADR-015-disaster-recovery.md) **Implementation:**

- `rclone sync` of the Garage data directory to a separate location on a documented schedule
- Snapshot schedule and destination documented in the Garage runbook
- TODO: define snapshot frequency and retention policy

### [ADR-011](decisions/ADR-011-observability.md): Observability

**Rule OBS-01: Deploy the full three-signal stack: kube-prometheus-stack, Loki, Grafana Tempo, and OTel Operator.** **Implementation:**

- Deployed as ArgoCD Applications under `kubernetes/apps/observability/`
- OTel Operator: DaemonSet mode for node-level collection; Deployment mode for receiving traces
- Tempo deployed now, even without application instrumentation, so no retrofit is needed when tracing begins

**Rule OBS-02: All observability PVCs use `longhorn-single-replica`.** **Implementation:**

- StorageClass `longhorn-single-replica` on: Prometheus PVC, Loki PVC, Tempo PVC, Grafana PVC, Alertmanager PVC
- Prometheus retention: 30 days
- Exception: the signal-cli-rest-api registration PVC uses `longhorn` (3 replicas), see ALT-02 and [ADR-012](decisions/ADR-012-alerting.md)

**Rule OBS-03: Integrate Grafana with Authentik via native OIDC (`auth.generic_oauth`), not forward auth.** **Implementation:**

- Config key: `auth.generic_oauth` in the Grafana Helm values
- Values file (planned, not yet created): `kubernetes/apps/observability/grafana/values.secret.yaml` (SOPS-encrypted)
- Keep `auth.generic_oauth` values in sync with the Authentik application config, because drift breaks Grafana login

**Rule OBS-04: Scrape Talos node metrics via `ScrapeConfig` with explicit static targets.** **Implementation:**

- Resource type: `ScrapeConfig` (prometheus-operator v1alpha1)
- Target port: `11234` on each node IP
- Require a `CiliumNetworkPolicy` allow rule in `monitoring`, permitting ingress from the Prometheus pod to port `11234` on node IPs

### [ADR-012](decisions/ADR-012-alerting.md): Alerting

**Rule ALT-01: Route all Alertmanager alerts to signal-cli-rest-api via `webhook_configs`.** **Implementation:**

- Alertmanager config key: `webhook_configs[].url: 'http://signal-cli-rest-api.observability.svc:8080/v2/send'`
- `send_resolved: true` on all receivers
- Group config: `group_wait: 30s`, `group_interval: 5m`, `repeat_interval: 4h`

**Rule ALT-02: Store signal-cli-rest-api registration data on a `longhorn` (3-replica) PVC.** **Implementation:**

- StorageClass: `longhorn` (3 replicas), the only observability component that must not use `longhorn-single-replica`
- One-time registration through the REST API (`/v1/register/<number>` then `/v1/register/<number>/verify/<code>`), no `kubectl exec` into the container required; documented in the Phase 6 runbook
- TODO: document the recovery procedure if the PVC is lost

### [ADR-013](decisions/ADR-013-cilium-network-policy.md): Cilium NetworkPolicy & Trivy

**Rule SEC-05: Apply a default-deny `CiliumNetworkPolicy` to every namespace at creation time.** **Implementation:**

- Template (apply to every new namespace):

  ```yaml
  apiVersion: cilium.io/v2
  kind: CiliumNetworkPolicy
  metadata:
    name: default-deny
    namespace: <app-namespace>
  spec:
    endpointSelector: {}
    ingress:
      - {}
    egress:
      - toEndpoints:
          - matchLabels:
              io.kubernetes.pod.namespace: kube-system
              k8s-app: kube-dns
        toPorts:
          - ports:
              - port: "53"
                protocol: UDP
              - port: "53"
                protocol: TCP
  ```

- Allow both TCP and UDP on port 53 to kube-dns; CoreDNS truncates large responses over UDP (TC bit set) and expects the client to retry over TCP

- Workload-specific allow rules deploy as separate `CiliumNetworkPolicy` resources alongside the workload manifests

- Phase 8 is a dedicated audit-and-tighten pass for cross-namespace paths

**Rule SEC-06: Use `CiliumNetworkPolicy` CRDs, not standard `networking.k8s.io/v1 NetworkPolicy`.** **Implementation:**

- `apiVersion: cilium.io/v2` on all network policy resources
- Hubble must be enabled to surface policy drops: `helm show values cilium/cilium | grep hubble.enabled` must be `true`
- Never mix `networking.k8s.io/v1 NetworkPolicy` and `CiliumNetworkPolicy` in the same namespace

**Rule SEC-07: Deploy Trivy Operator for continuous in-cluster CVE scanning.** **Implementation:**

- Trivy Operator deployed as an ArgoCD Application; `ServiceMonitor` enabled for Prometheus scraping
- Alert threshold: critical severity CVEs only in Alertmanager; medium/low surfaced in Grafana dashboards for periodic review
- Trivy needs an explicit outbound CiliumNetworkPolicy allow rule to GitHub releases for daily vulnerability database updates

### [ADR-014](decisions/ADR-014-kyverno.md): Kyverno Policy Engine

**Rule POL-01: Roll out all Kyverno policies in Audit mode before switching to Enforce.** **Implementation:**

- Sequence: deploy Kyverno in Audit → resolve all violations → switch to Enforce
- `failurePolicy: Ignore` for the initial rollout; revisit after Kyverno stability is established
- The Kyverno namespace must be excluded from its own policies, so configure the exclusion at deploy time

**Rule POL-02: Require CPU and memory limits on all containers.** **Implementation:**

- Kyverno `ClusterPolicy` with `validate` rule requiring `resources.limits.cpu` and `resources.limits.memory`
- Mutating policy injects defaults at admission in development namespaces
- CI check: `kube-score` flags missing limits before the cluster sees the manifest

**Rule POL-03: Prohibit `latest` and mutable image tags.** **Implementation:**

- Disallowed tags: `:latest`, `:main`, `:stable`, `:edge`, configured as a list in the Kyverno policy
- All pinned tags managed by Renovate (see DEP-01) via automated PRs
- Kyverno validates; Renovate keeps pinned tags current

**Rule POL-04: Restrict image sources to approved registries.** **Implementation:**

- Approved registry domains: Docker Hub (`docker.io`), GHCR (`ghcr.io`), Quay.io (`quay.io`) and `registry.k8s.io` (Kubernetes Special Interest Group (SIG) images, required for the NFS CSI driver). The allowlist is the registry domain, not the Docker Hub "official images" namespace, so third-party namespaces (e.g. `longhornio/*`) on those registries are allowed.
- Kyverno `ClusterPolicy` with `validate` rule checking the `image` field against the approved list
- A new registry requires a deliberate policy update and ADR note

**Rule POL-05: Reject privileged containers unless a named `PolicyException` is committed to git.** **Implementation:**

- Current approved exceptions (each has a `PolicyException` resource with a rationale comment):
  - Longhorn (block device management)
  - Cilium (eBPF program loading)
  - NFS CSI driver (kernel NFS mounts), with its `registry.k8s.io` images pinned through explicit Helm `image.*.tag` values (chart default is `latest`, which violates POL-03)
- `PolicyException` resource committed under `kubernetes/infrastructure/kyverno/exceptions/`
- No silent carve-outs via namespace label overrides

### [ADR-015](decisions/ADR-015-disaster-recovery.md): Disaster Recovery

**Rule DR-01: Use three independent backup layers: Velero, etcd snapshot, and CNPG Barman.** **Implementation:**

- Velero: daily, 7-day retention, writes to Garage S3
- `talosctl etcd snapshot`: daily, 7 snapshots retained, uploads to Garage S3
- CNPG Barman: continuous WAL archiving + periodic base backups per Cluster
- Full restore sequence: documented in `docs/runbooks/cluster-rebuild.md`

**Rule DR-02: Always include the cert-manager namespace in Velero backups.** **Implementation:**

- Velero backup spec: explicitly include the `cert-manager` namespace
- Velero backup spec: explicitly exclude `kube-system` (Talos and CoreDNS are reproducible from git)
- `cert-manager` must never appear on a Velero exclusion list

**Rule DR-03: Test Velero restore against a scratch cluster before treating backups as production.** **Implementation:**

- Phase 9 deliverable: restore test against an isolated cluster; RTO estimate updated after the test
- Test must cover: CNPG Cluster restore triggering Barman WAL recovery automatically
- Restore sequence walk-through documented in `docs/runbooks/cluster-rebuild.md`

### [ADR-016](decisions/ADR-016-ansible-for-proxmox-host-configuration.md): Ansible

**Rule CFG-01: All Proxmox host configuration changes go through `ansible/`, never direct SSH.** **Implementation:**

- Roles: `proxmox_base`, `fan_control`, `pve_exporter`, `custom_scripts`
- Main playbook: `ansible/playbooks/bootstrap.yaml`, safe to re-run at any time
- Verify playbook: `ansible/playbooks/verify.yaml`, checks state without changes, runs in CI on every PR touching `ansible/`

**Rule CFG-02: Ansible owns the OS layer; OpenTofu owns the resource layer. Never let them overlap.** **Implementation:**

- Ansible scope: apt repositories, packages, sysctl, SSH hardening, fan control, pve-exporter, host-level scripts
- OpenTofu scope: VMs, LXCs, DNS records, object storage buckets, Kubernetes workloads
- Any new host-level concern goes into `ansible/`; any new Proxmox resource goes into `infrastructure/units/`

### [ADR-017](decisions/ADR-017-infrastructure-diagramming-strategy.md): Diagramming

**Rule DOC-01: Auto-generate OpenTofu diagrams via inframap on every merge touching `infrastructure/`.** **Implementation:**

- Command: `tofu state pull | inframap generate --tfstate | dot -Tsvg > docs/diagrams/terraform.svg`
- Requires a self-hosted runner with Garage S3 network access
- The pipeline commits the diagrams back with `[skip ci]` to avoid a loop

**Rule DOC-02: Auto-generate Kubernetes workload diagrams via KubeDiagrams on every merge touching `kubernetes/`.** **Implementation:**

- Commands: `kubediagrams kubernetes/infrastructure/` and `kubediagrams kubernetes/apps/`
- CI needs no live cluster access: it runs from git manifests
- Divergence check: run `kubediagrams --from-cluster` manually and diff against the CI output

**Rule DOC-03: Update `docs/diagrams/architecture.md` (Mermaid) as part of the definition of done for any topology change.** **Implementation:**

- Triggers for update: new LXC, new major service, changed network path, new storage tier
- Mermaid renders natively in Gitea and Codeberg, no build step needed
- Checklist item on topology-change PRs: "architecture.md updated?"

### [ADR-018](decisions/ADR-018-tailscale.md): Tailscale

**Rule VPN-01: Replace the Tailscale default allow-all ACL policy immediately after provisioning.** **Implementation:**

- Owner: full access to all services, SSH and the Proxmox management port
- Additional users: HTTP/HTTPS to internal services only; SSH and the Proxmox port are owner-only
- Sanitised ACL template committed to the public Codeberg mirror

**Rule VPN-02: Register both AdGuard LXC IPs as restricted nameservers in Tailscale MagicDNS.** **Source:** also [ADR-019](decisions/ADR-019-adguard-ha-setup.md) **Implementation:**

- MagicDNS config: both AdGuard IPs registered as restricted nameservers scoped to `yourdomain.internal`
- This extends AdGuard HA failover (see [ADR-019](decisions/ADR-019-adguard-ha-setup.md)) to Tailscale-connected devices
- Verify: from a Tailscale-connected device, `dig @<tailscale-ip> grafana.yourdomain.internal` must resolve

### [ADR-019](decisions/ADR-019-adguard-ha-setup.md): AdGuard HA

**Rule DNS-01: Run two AdGuard Home LXCs with `adguardhome-sync` pushing config from primary to replica every 5 minutes.** **Implementation:**

- `adguardhome-sync` cron: `*/5 * * * *` with `runOnStart: true` and `continueOnError: true`
- Credentials: SOPS-encrypted in `adguardhome-sync.yaml` on the primary LXC
- The MikroTik DHCP server lists both IPs as DNS resolvers; clients fall back automatically

**Rule DNS-02: All AdGuard config changes go through OpenTofu targeting the primary only.** **Implementation:**

- OpenTofu unit: `infrastructure/units/public/adguard/`
- The replica web UI is a passive canary: unexplained visible drift from the primary means the sync process has failed silently
- Never `terragrunt apply` against the replica unit
- TODO: the adguard unit and `adguard-config` catalog are empty, so DNS rewrites are not in git despite this rule. Until a real unit lands, slices that need rewrites use the manual AdGuard UI/API host step and record it in their runbook (gap found 2026-09-22)

### [ADR-020](decisions/ADR-020-storage-tier-strategy.md): Storage Tiers

**Rule STR-03: Format Tier 1 drives (irreplaceable data) as native btrfs RAID 1 with no mdadm or LVM.** **Implementation:**

- btrfs RAID 1 profile for both data and metadata: `mkfs.btrfs -d raid1 -m raid1 /dev/sdX /dev/sdY`
- Weekly `btrfs scrub` followed by `duperemove` incremental deduplication
- Alertmanager alert on any `btrfs scrub status` error output

**Rule STR-04: Pool Tier 2 drives (recreatable data) with mergerfs JBOD using `mfs` create policy.** **Implementation:**

- Each drive formatted individually: `mkfs.btrfs /dev/sdX` (single profile)
- mergerfs mount point: `/mnt/bulk` with create policy `mfs` and `minfreespace=50G`
- Adding a drive: format → mount → add to mergerfs source list → remount; no rebuild required

**Rule STR-05: Set `reclaimPolicy: Retain` on all NFS StorageClasses.** **Implementation:**

- `nfs-tier1` StorageClass: `reclaimPolicy: Retain`
- `nfs-tier2` StorageClass: `reclaimPolicy: Retain`
- Released PVs need explicit manual cleanup after confirming the data is no longer needed

**Rule STR-06: Run weekly `btrfs scrub` on all drives across both tiers.** **Implementation:**

- Tier 1: weekly scrub on the btrfs RAID 1 pool
- Tier 2: weekly scrub on each individual btrfs single drive
- `btrfs scrub status` output is the primary storage health signal; Alertmanager alert on any errors

### [ADR-H](decisions/ADR-H-hardware-platform.md): Hardware Platform

**Rule HW-01: Enable AMD EXPO in BIOS to run DDR5 at 6000MHz.** **Implementation:**

- BIOS setting: enable the EXPO profile (the 6000MHz CL36 kit)
- Verify post-boot: `dmidecode --type memory | grep Speed` must show 6000MT/s
- Without EXPO, LLM inference and Immich ML workloads are meaningfully slower

**Rule HW-02: Accept that there is no offsite backup for Tier 1 storage until one exists.** **Source:** also [ADR-020](decisions/ADR-020-storage-tier-strategy.md) **Implementation:**

- Known gap: accepted, no offsite copy yet
- Current mitigation: btrfs RAID 1 covers single-drive failure
- Deliverable: offsite backup destination and rclone/restic job for Tier 1 data

## Conflicts & Exceptions

### Exception approval process

Any deviation from a rule in this rulebook requires:

1. **Owner sign-off.** The infrastructure owner must explicitly approve the exception.
2. **ADR note.** The exception must be documented in the relevant ADR's Consequences section or as an amendment, with the rule waived, the reason and the expected duration.
3. **Time-bound or permanent classification.** Temporary exceptions (e.g., during a migration phase) must include a resolution trigger. Permanent exceptions must justify why the rule does not apply there.
4. **PR reference.** The exception PR must link to the ADR update.

### Known rule interactions to watch

- **STR-01 vs OBS-02:** The default StorageClass is `longhorn` (3 replicas), but observability PVCs must use `longhorn-single-replica`. Any observability PVC without an explicit `storageClassName` silently takes the 3-replica default, so always set `storageClassName` explicitly.
- **POL-05 vs STR-01/SEC-05:** Longhorn and Cilium need privileged containers and broad host access. Their `PolicyException` resources are pre-approved, but any change to those workloads must re-verify the exception.
- **GIT-01 vs K8S-02:** The ArgoCD bootstrap is the only install outside the GitOps loop, and it runs as a declarative OpenTofu `helm_release`, not a manual Helm command. Any other imperative step must be reviewed against K8S-02.
- **SEC-01 vs IaC-04:** SOPS-encrypted files are safe to publish. Check that `.sops.yaml` path patterns cover all new secret file locations before adding them to the public mirror.

### Conflict reporting

If a change satisfies one rule while violating another, open a discussion thread on the PR and tag it `conflict`. Do not merge until the conflict is resolved and the ADRs are updated.

## ADRs That Could Not Be Converted Into Rules

No ADR was left without a rule: every ADR here has a Decision section with actionable content. Three produced fewer rules than expected, because their content is mainly contextual or comparative. Their key decisions are captured; read the source ADR for the full reasoning:

- **[ADR-001](decisions/ADR-001-kubernetes.md):** Most decision content folded into K8S-01/K8S-02; the alternatives analysis (Nomad, k3s, Docker Swarm) is context, not rules.
- **[ADR-011](decisions/ADR-011-observability.md):** The managed service rejection (Datadog, Grafana Cloud) is rationale, not a rule; captured in OBS-01.
- **[ADR-014](decisions/ADR-014-kyverno.md):** The OPA Gatekeeper vs Kyverno comparison is context; the rules capture the outcomes.

## Changelog

| Version | Date       | Notes                                                                                                                             |
| ------- | ---------- | --------------------------------------------------------------------------------------------------------------------------------- |
| v1.0    | 2026-04-22 | Initial rulebook derived from [ADR-000](decisions/ADR-000-project-goals.md) through [ADR-H](decisions/ADR-H-hardware-platform.md) |
