# Runbook: ArgoCD Break-Glass Recovery

Recovers ArgoCD when it cannot heal itself. Covers crash-looping components,
self-management loops, a lost admin password, and a broken repository
connection ([ADR-003](../decisions/ADR-003-argocd.md)). The GitOps loop is the
only normal write path to the cluster ([ADR-000](../decisions/ADR-000-project-goals.md));
every step here is an exception and ends when the loop takes over again.

## Prerequisites

- A workstation with the cluster admin kubeconfig (context
  `admin@talos-cluster-01`, written by `talosctl`)
- Terragrunt and `kubectl` installed
- For the reinstall path: the sops age key for
  `infrastructure/secrets.yaml`, plus the dedicated ArgoCD age keypair when
  the in-cluster key Secret must be recreated ([ADR-009](../decisions/ADR-009-sops.md))
- Never run two applies against the same unit at once; the backend lockfile
  makes the second run fail

## 1. Symptoms

| Symptom                                                         | Likely cause                                 | Fix    |
| --------------------------------------------------------------- | -------------------------------------------- | ------ |
| `argocd-server` or `argocd-controller` pods in CrashLoopBackOff | Bad Helm values, broken Redis, corrupt state | Step 3 |
| Application `argocd` fights its own sync, resources flap        | Self-management loop                         | Step 5 |
| Login rejected, admin password unknown                          | Lost credential                              | Step 4 |
| Repository shows connection/auth errors, apps stop syncing      | Gitea URL changed, expired token             | Step 6 |
| Whole `argocd` namespace gone or release broken                 | Failed component                             | Step 3 |

Diagnose first:

```bash
kubectl -n argocd get pods
kubectl -n argocd logs deploy/argocd-server --tail=100
kubectl -n argocd logs deploy/argocd-application-controller --tail=100
```

## 2. Get API and UI access

The server runs with `server.insecure=true`: plain HTTP inside the cluster,
TLS termination happens outside (port-forward today, Gateway later,
[ADR-003](../decisions/ADR-003-argocd.md)). Access goes through port-forward
only until Authentik OIDC is live:

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:80
```

Open `http://localhost:8080` (not https). The UI works while pods run; a
crash-looping server still leaves the API usable through `kubectl` and the
ArgoCD CRDs directly, which the steps below use.

## 3. Reinstall ArgoCD from IaC

The install is idempotent OpenTofu: the `helm_release` reconciles the
release `argocd` in namespace `argocd`, and the inline `kubectl_manifest`
reapplies the root App of Apps Application `root`
([ADR-002](../decisions/ADR-002-opentofu-terragrunt.md)). From the repo root:

```bash
cd infrastructure/stacks/public/argocd
SOPS_AGE_KEY=<argocd-keypair-private-key> terragrunt stack run apply
```

Notes:

- `SOPS_AGE_KEY` is optional. Exporting it recreates the in-cluster Secret
  `sops-age`; leaving it unset skips that resource without error
- The apply also refreshes Secrets `gitea-repo-creds` (namespace `argocd`)
  and `dns01-api-token` (namespace `cert-manager`, the DNS provider
  credential) from the sops `dns_provider` section of
  `infrastructure/secrets.yaml`
- This repairs a broken release or a deleted namespace. It does not repair a
  bad git commit; fix git instead and let sync converge

## 4. Reset the admin password

Two paths. Prefer the first.

### Option A: regenerate the initial secret

```bash
kubectl -n argocd patch secret argocd-secret \
  -p '{"stringData":{"admin.password":null,"admin.passwordMtime":null}}'
kubectl -n argocd delete secret argocd-initial-admin-secret
kubectl -n argocd rollout restart deployment/argocd-server
kubectl -n argocd rollout status deployment/argocd-server
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

The first patch clears `admin.password` and `admin.passwordMtime` from
Secret `argocd-secret`. ArgoCD stores only a one-way bcrypt hash there, so
the server cannot recover the forgotten password from it - deleting
`argocd-initial-admin-secret` alone does not reveal the old password. With
both keys cleared and the server restarted, ArgoCD generates a new random
password on startup, writes the new bcrypt hash into `argocd-secret`, and
mirrors the plaintext into `argocd-initial-admin-secret`. The automated sync
of Application `argocd` does not revert this: git declares no
`admin.password`, so the generated hash stays until the next login writes a
new one. Log in as user `admin` with the value read above.

### Option B: set a known password via a temporary values override

Requires `htpasswd` (from apache2-utils) or any bcrypt generator. Generate a
hash and pass it in a temporary values file:

```bash
htpasswd -bnBC 10 "" '<new-password>' | tr -d ':\n' > /tmp/hash
cat >/tmp/argocd-breakglass-values.yaml <<EOF
configs:
  secret:
    argocdServerAdminPassword: $(cat /tmp/hash)
EOF
helm -n argocd upgrade argocd argo/argo-cd \
  --version 9.4.3 -f /tmp/argocd-breakglass-values.yaml
rm -f /tmp/hash /tmp/argocd-breakglass-values.yaml
```

The `--version 9.4.3` above is the chart version this runbook was written
against; check the version pinned in
`infrastructure/catalogs/public/k8s-app/argocd.tf` and use that value -
Renovate bumps the pin over time. This upgrade is break-glass only: the next
automated sync of Application `argocd` reverts to the git-declared values,
which removes the override again.

## 5. Break a self-management loop

Self-managed Applications can modify or delete their own configuration; a
wrong commit then makes sync fight every manual fix. Detach the automation,
fix git, converge, restore automation:

```bash
kubectl -n argocd patch app argocd --type merge \
  -p '{"spec":{"syncPolicy":null}}'
```

Then:

1. Fix the offending manifests in git and push
2. Sync manually until the application converges:
   `kubectl -n argocd get app argocd -w` (or trigger a sync in the UI)
3. Restore the automated policy:

```bash
kubectl -n argocd patch app argocd --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
```

Confirm the restored policy matches the Application manifest in git, so the
next sync does not flag drift.

## 6. Repair the repository connection

The root Application clones the monorepo using Secret `gitea-repo-creds`
(namespace `argocd`, label
`argocd.argoproj.io/secret-type=repository`). Its keys map to the sops
values: `url` from `gitea.url`, `username` from `gitea.username`,
`password` from `gitea.token`.

Compare the live Secret against Gitea:

```bash
kubectl -n argocd get secret gitea-repo-creds \
  -o jsonpath='{.data.url}' | base64 -d; echo
kubectl -n argocd get secret gitea-repo-creds \
  -o jsonpath='{.data.username}' | base64 -d; echo
kubectl -n argocd get secret gitea-repo-creds \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

If the token expired or was revoked:

1. Rotate the token in Gitea (read-only scope is enough)
2. Edit `infrastructure/secrets.yaml` (`sops`) and replace `gitea.token`
3. Rerun the stack apply from step 3; OpenTofu updates the Secret in place
4. Confirm the repository connects (UI Settings, or watch Application sync)

## 7. Verify recovery

Work through all checks before declaring the incident closed:

```bash
kubectl -n argocd get app root
kubectl -n argocd get apps
kubectl -n argocd get pods
```

Checklist:

- [ ] Application `root` reports `Synced` and `Healthy`
- [ ] Child Applications appear (`kubectl -n argocd get apps` matches the
  tree under `kubernetes/`)
- [ ] One child, `cert-manager`, reaches `Healthy` end-to-end: its pods run
  and the webhook answers
- [ ] No pod in namespace `argocd` restarts in a loop over several minutes
- [ ] UI login works with the current credentials (after a step 4 reset)

## What this runbook does not cover

- Full cluster rebuild from scratch: see
  `docs/runbooks/cluster-rebuild.md` (GAP: not yet written)
- Velero restores and etcd snapshots: [ADR-015](../decisions/ADR-015-disaster-recovery.md)
- Talos and Kubernetes upgrades: see
  [the upgrade runbook](talos-k8s-upgrade.md)

## Key material

Step 3 injects the private key of the dedicated ArgoCD age keypair into
Secret `argocd/sops-age` ([ADR-009](../decisions/ADR-009-sops.md)). This
key is separate from the developer master key and from the sops age key for
`infrastructure/secrets.yaml`:

- Private key location: `~/.config/sops/age/argocd.txt`, untracked, with a
  backup copy in the password manager
- The key never enters the default `keys.txt`: ordinary host-side `sops`
  calls do not load it
- An empty `SOPS_AGE_KEY` is valid: the apply in step 3 skips the Secret
  cleanly instead of failing

Export the key before an apply that must recreate the Secret:

```bash
export SOPS_AGE_KEY="$(cat ~/.config/sops/age/argocd.txt)"
```
