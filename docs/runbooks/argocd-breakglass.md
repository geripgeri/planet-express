# Runbook: ArgoCD Break-Glass Recovery

Recovers ArgoCD when it cannot heal itself: crash-looping components,
self-management loops, a lost admin password, and a broken repository
connection ([ADR-003](../decisions/ADR-003-argocd.md)). Every step here is an
exception. The GitOps loop is the only normal write path
([ADR-000](../decisions/ADR-000-project-goals.md)).

## Prerequisites

- A workstation with the cluster admin kubeconfig (context
  `admin@talos-cluster-01`, written by `talosctl`)
- Terragrunt and `kubectl` installed
- For the reinstall path: the sops age key for `infrastructure/secrets.yaml`,
  plus the dedicated ArgoCD age keypair when the in-cluster key Secret must be
  recreated ([ADR-009](../decisions/ADR-009-sops.md))
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

Plain HTTP inside the cluster (`server.insecure=true`); TLS terminates outside
(port-forward, or the shared Gateway once Authentik OIDC is live,
[ADR-003](../decisions/ADR-003-argocd.md)).

Normal login is OIDC via Authentik at `https://argocd.example.com`. The local
`admin` account is break-glass only (rotation: step 4 and
[authentik-deploy](authentik-deploy.md)).

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:80
```

Open `http://localhost:8080` (not https). The UI works while pods run. With
a crash-looping server, `kubectl` and the ArgoCD CRDs still work.

## 3. Reinstall ArgoCD from IaC

Idempotent OpenTofu. `helm_release` reconciles release `argocd` in namespace
`argocd`; `kubectl_manifest` reapply App of Apps `root` and self-management
Application `argocd` ([ADR-002](../decisions/ADR-002-opentofu-terragrunt.md)).
From the repo root:

```bash
cd infrastructure/stacks/public/argocd
SOPS_AGE_KEY=<argocd-keypair-private-key> terragrunt stack run apply
```

- `SOPS_AGE_KEY` is optional. Exporting it recreates the in-cluster Secret
  `sops-age`; leaving it unset skips that resource without error
- The apply also refreshes `gitea-repo-creds` (namespace `argocd`) and
  `dns01-api-token` (namespace `cert-manager`, the DNS credential) from the sops
  `dns_provider` section of `infrastructure/secrets.yaml`
- This repairs a broken release or a deleted namespace. It does not repair a
  bad git commit. Fix git and let sync converge

## 4. Reset the admin password

Two paths, prefer the first. Run only for break-glass recovery or the one-time
rotation in [authentik-deploy](authentik-deploy.md) step 8.

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

`argocd-secret` holds a one-way bcrypt hash, so deleting
`argocd-initial-admin-secret` alone never reveals the old password. With
`admin.password` and `admin.passwordMtime` cleared and the server restarted,
ArgoCD generates a random password, stores the hash in `argocd-secret`, and
mirrors the plaintext into `argocd-initial-admin-secret`. Sync of Application
`argocd` does not revert this: git declares no `admin.password`, so the hash
stays until the next login. Log in as `admin` with the value read above.

### Option B: set a known password via a temporary values override

Requires `htpasswd` (from apache2-utils) or any bcrypt generator.

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

Check the pin in `infrastructure/catalogs/public/k8s-app/argocd.tf` and use
that value instead of `--version 9.4.3` (Renovate bumps it). Break-glass only:
the next sync of Application `argocd` reverts to the git-declared values and
removes the override.

Normal path for config-only ArgoCD changes: commit under
`kubernetes/infrastructure/argocd/` and let Application `argocd` sync. Check
with `kubectl -n argocd get app argocd`. Everything below is break-glass.

## 5. Break a self-management loop

A wrong commit makes sync fight every manual fix. Detach, fix git, converge,
restore:

```bash
kubectl -n argocd patch app argocd --type merge \
  -p '{"spec":{"syncPolicy":null}}'
```

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
`argocd.argoproj.io/secret-type=repository`). Its keys map to the sops values:
`url` from `gitea.url`, `username` from `gitea.username`, `password` from
`gitea.token`.

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

Run all checks before closing the incident:

```bash
kubectl -n argocd get app root
kubectl -n argocd get apps
kubectl -n argocd get pods
```

- [ ] Application `root` reports `Synced` and `Healthy`
- [ ] Child Applications appear (`kubectl -n argocd get apps` matches the
  tree under `kubernetes/`)
- [ ] One child, `cert-manager`, reaches `Healthy` end-to-end: its pods run
  and the webhook answers
- [ ] No pod in namespace `argocd` restarts in a loop over several minutes
- [ ] UI login works with the current credentials (after a step 4 reset)

## What this runbook does not cover

- Full cluster rebuild from scratch: see `docs/runbooks/cluster-rebuild.md`
  (GAP: not yet written)
- Velero restores and etcd snapshots:
  [ADR-015](../decisions/ADR-015-disaster-recovery.md)
- Talos and Kubernetes upgrades: see
  [the upgrade runbook](talos-k8s-upgrade.md)

## Key material

Step 3 injects the private key of the dedicated ArgoCD age keypair into Secret
`argocd/sops-age` ([ADR-009](../decisions/ADR-009-sops.md)). It is separate
from the developer master key and from the sops age key for
`infrastructure/secrets.yaml`:

- Private key location: `~/.config/sops/age/argocd.txt`, untracked, with a
  backup copy in the password manager
- The key never enters the default `keys.txt`: ordinary host-side `sops` calls
  do not load it
- An empty `SOPS_AGE_KEY` is valid; step 3 skips the Secret instead of failing

Export the key before an apply that must recreate the Secret:

```bash
export SOPS_AGE_KEY="$(cat ~/.config/sops/age/argocd.txt)"
```
