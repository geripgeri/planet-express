# Runbook: Authentik Slice 1 Deploy

Deploys k8s Authentik, the CNPG operator, the Authentik database with WAL
archiving, `auth.example.com` exposure, and ArgoCD OIDC login
([ADR-008](../decisions/ADR-008-authentik.md),
[ADR-006](../decisions/ADR-006-cloudnativepg.md),
[ADR-021](../decisions/ADR-021-public-mirror-privacy-partitioning.md)).
Everything runs on the host workstation: the sandbox has no cluster access
and no sops age key. Public examples use `auth.example.com`; replace it with
your private deployment hostname only in private paths or SOPS-encrypted values.

## Prerequisites

- Host with the cluster admin kubeconfig (context `admin@talos-cluster-01`)
- `sops`, `terragrunt`, `kubectl`, `openssl`, and `python3` installed; the sops age key at
  the default location (`~/.config/sops/age/keys.txt`)
- Branch `feat/authentik-slice1` checked out on the host before merge — the
  bootstrap script fills values before the merge-triggered apply
- Access steps from [garage-lxc-setup](garage-lxc-setup.md) for the Garage
  bucket CLI
- Never run two applies against the same unit at once; the backend
  lockfile makes the second run fail

## 1. Preflight

1. StorageClass check (AUTH-03: 3 Longhorn replicas on one node needs soft
   anti-affinity):

   ```bash
   kubectl get storageclass longhorn
   kubectl -n longhorn-system get settings.longhorn.io replica-soft-anti-affinity -o yaml
   ```

   If the setting is `false`, set it to `true` in the Longhorn values and
   let sync converge, or lower the replica count and record the deviation
   in the ADR follow-up. A 3-replica PVC cannot schedule otherwise.

2. Backup bucket and key (DB-02): apply the dedicated Garage unit after the
   Garage LXC is ready. The `tofu-state` key is not reused for application
   backups.

   ```bash
   cd infrastructure/stacks/public/garage
   terragrunt stack run plan
   terragrunt stack run apply
   cd ../../../..
   K8S_AK="$(cd infrastructure/units/public/garage/k8s-backup && terragrunt output -raw access_key_id)"
   K8S_SK="$(cd infrastructure/units/public/garage/k8s-backup && terragrunt output -raw secret_access_key)"
   printf '%s' "$K8S_AK" \
     | python3 -c 'import json, sys; sys.stdout.write(json.dumps(sys.stdin.read()))' \
     | sops set --value-stdin infrastructure/secrets.yaml \
         '["garage"]["k8s_backup"]["access_key_id"]'
   printf '%s' "$K8S_SK" \
     | python3 -c 'import json, sys; sys.stdout.write(json.dumps(sys.stdin.read()))' \
     | sops set --value-stdin infrastructure/secrets.yaml \
         '["garage"]["k8s_backup"]["secret_access_key"]'
   unset K8S_AK K8S_SK
   ```

   The unit creates and binds the `k8s-backup` bucket to the
   `authentik-backup` key. The SOPS values are required before running the
   bootstrap script. If an earlier manual bootstrap already created the
   bucket, stop and import it into this unit before applying; do not create a
   second bucket.

3. DNS rewrites (gap: not in git yet, see rulebook DNS-02 TODO): add two
   rewrites in the AdGuard UI/API on the primary — `auth.example.com` and
   `argocd.example.com`, both to the shared-gateway node address.

## 2. Fill bootstrap values (host, before merge)

On the host clone of the feature branch:

```bash
scripts/bootstrap_authentik_env.sh
git diff --stat
git add infrastructure/secrets.yaml kubernetes/
git commit -m "chore(authentik): fill bootstrap values"
git push
```

The script prints no values. It reads `network_config.garage_lxc.ip`,
`garage.k8s_backup.*`, and `gitea.url` from `infrastructure/secrets.yaml`,
generates the database password and secret key, re-encrypts in place, and
refreshes the encrypted `authentik-backup` Secret from the dedicated Garage
key on every run. The database password stays in sync between `db-secret` and
`config-secret`.

Sandbox flow note: `leela export` → host `leela fetch` → run the fill commit
on the host feature branch → `fry push` / `fry merge all`.

## 3. Apply the ksops tooling to ArgoCD

```bash
(
  cd infrastructure/units/public/argocd
  terragrunt apply
)
```

Then verify:

```bash
kubectl -n argocd get deploy argocd-repo-server \
  -o jsonpath='{.spec.template.spec.initContainers[*].name}{"\n"}'
kubectl -n argocd get cm argocd-cm \
  -o jsonpath='{.data.kustomize\.buildOptions}{"\n"}'
```

Expected: `ksops-install` and
`--enable-alpha-plugins --enable-exec`. Until this apply runs, the
`authentik-infra` Application shows a comparison error on the ksops
generator — expected, it heals after the apply.

## 4. Let the child Applications deploy

```bash
kubectl -n argocd get apps -w
```

Order of events:

1. `cnpg-operator` — `CreateNamespace=true` creates `cnpg-system`; wait for
   `kubectl get crd postgresql.cnpg.io`
2. `authentik-infra` — namespace, Secrets, and CNPG `Cluster`; wait for
   `kubectl -n authentik get cluster authentik -o wide` to report Ready and
   both PVCs Bound
3. `authentik-route` — the private HTTPRoute; wait for
   `kubectl -n authentik get httproute authentik -o wide` to report Accepted
4. `authentik` — the chart; wait for pods `authentik-server` and
   `authentik-worker` Running (first boot runs migrations, allow several
   minutes)

If `authentik` fails because namespace `authentik` does not exist yet,
it retries: the chart Application carries `CreateNamespace=true` and the
infra Application creates the same namespace as a manifest.

## 5. Initial admin and API token

```bash
kubectl -n authentik port-forward svc/authentik-server 9000:80
```

1. Open `https://localhost:9000`, complete the initial-admin wizard,
   store the password in the password manager

2. Create an API token for the admin user in the Authentik UI
   (User → Tokens), then store it without echoing it:

   ```bash
   read -rs T
   printf '%s' "$T" \
     | python3 -c 'import json, sys; sys.stdout.write(json.dumps(sys.stdin.read()))' \
     | sops set --value-stdin infrastructure/secrets.yaml \
         '["authentik"]["api_token"]'
   unset T
   ```

3. Set the provider base URL once (the value lives in sops, not in git; the
   authentik unit and its issuer output both read it):

   ```bash
   sops set infrastructure/secrets.yaml '["authentik"]["url"]' \
     '"https://auth.example.com"'
   ```

## 6. Create the OIDC provider (AUTH-02)

```bash
(
  cd infrastructure/stacks/private/authentik
  terragrunt stack run plan   # review, then:
  terragrunt stack run apply
)
```

The `goauthentik` provider creates OAuth2 provider `argocd`, application
`ArgoCD` (slug `argocd`), and group `argocd-admins`. If plan rejects an
argument name, trust the plan error and adjust `main.tf` (the schema
lives in the provider docs, not in this repo).

## 7. Wire OIDC into ArgoCD

```bash
CID=$(cd infrastructure/units/public/authentik && terragrunt output -raw client_id)
CSEC=$(cd infrastructure/units/public/authentik && terragrunt output -raw client_secret)
printf '%s' "$CID" \
  | python3 -c 'import json, sys; sys.stdout.write(json.dumps(sys.stdin.read()))' \
  | sops set --value-stdin infrastructure/secrets.yaml \
      '["authentik"]["argocd_oidc"]["client_id"]'
printf '%s' "$CSEC" \
  | python3 -c 'import json, sys; sys.stdout.write(json.dumps(sys.stdin.read()))' \
  | sops set --value-stdin infrastructure/secrets.yaml \
      '["authentik"]["argocd_oidc"]["client_secret"]'
sops set infrastructure/secrets.yaml '["authentik"]["argocd_oidc"]["issuer"]' \
  '"https://auth.example.com/application/o/argocd/"'
(
  cd infrastructure/units/public/argocd
  terragrunt apply
)
unset CID CSEC
```

Verify the config key exists without printing values:

```bash
kubectl -n argocd get cm argocd-cm -o json \
  | python3 -c 'import sys,json; print("oidc.config" in json.load(sys.stdin)["data"])'
```

Expected: `True`.

## 8. Rotate the local admin password

The local `admin` account becomes break-glass only. Rotate its password
now and store the new value in the password manager — follow
[argocd-breakglass](argocd-breakglass.md) step 4 (Option A or B).

## 9. Exposure and login tests

From a machine on the home LAN (DNS rewrites from step 1 must exist):

1. `https://auth.example.com` serves the Authentik login
2. `https://argocd.example.com` redirects to Authentik; log in with a user
   that is a member of group `argocd-admins` and confirm the ArgoCD UI
   loads
3. A user outside the group reaches ArgoCD but gets read-only (RBAC
   `policy.default = role:readonly`)

Membership is managed in Authentik only — never with
`kubectl create rolebinding`.

## 10. Backup check

```bash
# garage CLI access per garage-lxc-setup runbook
garage bucket ls k8s-backup
kubectl -n authentik get cluster authentik -o jsonpath='{.status.backup}{"\n"}'
```

Expect objects under the bucket path and a configured backup in the
cluster status after the first WAL segment is archived (may take until
the first write-heavy migration activity settles).

## 11. Verification checklist

- [ ] `kubectl -n argocd get apps` shows `cnpg-operator`, `authentik-infra`,
  `authentik-route`, `authentik` all `Synced` and `Healthy`
- [ ] `kubectl -n authentik get pods` shows server, worker, and two
  database instances `Running`
- [ ] `https://auth.example.com` loads; initial admin login works
- [ ] `https://argocd.example.com` SSO login works for an `argocd-admins`
  member
- [ ] Local admin password rotated and stored (step 8)
- [ ] Garage bucket lists backup objects (step 10)
- [ ] Docker Authentik still serves its existing consumers (parallel
  run continues until the next slice)

## Failure handling

| Failure                                        | First response                                                                                           |
| ---------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| ksops comparison error on `authentik-infra`    | Confirm step 3 applied; repo-server has `ksops-install`                                                  |
| CNPG `Cluster` stuck not Ready                 | `kubectl -n authentik describe cluster authentik`; check PVC Bound and Longhorn replicas from step 1     |
| Chart pods crash on DB auth                    | Confirm bootstrap fill ran once, `db-secret` and `config-secret` passwords match (rerun script)          |
| OIDC redirect mismatch                         | Provider `redirect_uris` in the authentik unit vs `https://argocd.example.com/callback`; re-apply step 6 |
| Provider apply cannot reach `auth.example.com` | HTTPRoute/DNS from steps 1 and 4 not ready; provider only runs after the stack is live                   |
| Barman upload errors in CNPG logs              | `k8s-backup` bucket exists, `authentik-backup` key is valid, endpoint reachable from the cluster         |
