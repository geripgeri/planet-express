# Runbook: signal-cli-rest-api PVC Recovery

Recovers alert delivery when the signal-cli-rest-api registration PVC is lost
([ADR-012](../decisions/ADR-012-alerting.md), rule ALT-02 in the
[rulebook](../infra-rulebook.md)). The registration data (linked device
account) lives on a `longhorn` PVC with 3 replicas. Losing it unlinks the
Signal account from this server. Alertmanager keeps its config, but every
`/v2/send` call fails until one of the paths below runs.

Two paths:

- **Path A, re-register.** Fresh PVC, fresh registration. Always possible, needs a Signal verification code.
- **Path B, restore.** Longhorn backup restore, no registration needed. Needs a Longhorn backup.

Gap note: the signal-cli-rest-api manifests are not yet in `kubernetes/apps/`
(dns rewrites gap, rulebook DNS-02). Recreate the app from source until it
lands, then commit the manifests so the cluster converges from git.

## Prerequisites

- Cluster admin kubeconfig, `kubectl`
- Access to the Signal number: you get the verification code by SMS or call
- The Signal number, as used at first registration (`+<country><digits>`)
- `curl`

## Path A: re-register

### 1. Find and drop the broken PVC

```bash
kubectl -n observability get pvc,deploy,pods -l app=signal-cli-rest-api
```

Check the volume first. Longhorn keeps a broken volume even when the PVC is
gone, so delete the volume in the Longhorn UI if it shows up there.

```bash
kubectl -n observability scale deploy/signal-cli-rest-api --replicas=0
kubectl -n observability delete pvc <pvc-name>
```

The storage class stays `longhorn` (3 replicas, ALT-02). Do not accept a
`longhorn-single-replica` fallback.

### 2. Recreate the PVC and the app

Apply the manifests from the repo, then scale back up:

```bash
git -C <repo> checkout main -- kubernetes/apps/
kubectl -n observability apply -f <pvc-manifest>.yaml
kubectl -n observability scale deploy/signal-cli-rest-api --replicas=1
```

If the manifests are missing, this is a 100% IaC rule violation in progress.
Fix it: write the manifests, commit, let ArgoCD converge. A manual apply may
serve only as the temporary verification step.

### 3. Register

```bash
kubectl -n observability port-forward svc/signal-cli-rest-api 8080:8080
```

```bash
curl -X POST 'http://localhost:8080/v1/register/<number>'
```

The code arrives by SMS on the number. Enter it within the deadline:

```bash
curl -X POST 'http://localhost:8080/v1/register/<number>/verify/<code>'
```

This is a full new registration on this machine. Signal chat history and
group memberships that this number created are gone. Group members see a
device-less number rejoin as a plain number. Personal Signal on your phone
keeps its own history.

### 4. Check alert delivery

Send one test message:

```bash
curl -X POST 'http://localhost:8080/v2/send' \
  -H 'Content-Type: application/json' \
  -d '{"number": "<number>", "recipients": ["<number>"], "message": "test"}'
```

Then fire an Alertmanager test alert or wait for the next warning. Alert
recipients that reference group IDs are dead and need group names or plain
numbers instead.

## Path B: restore from Longhorn backup

Faster history-preserving path once Longhorn backups exist. Today no backup
target runs for Longhorn, so mark this path unavailable until the backup
target lands.

1. Scale the deployment to 0.
2. Longhorn UI, back to "Restore" the backup, restore to a new PVC in `observability` with storage class `longhorn`.
3. Point the deployment's volume at the restored PVC, keep the claim name stable or rename the volume reference in git.
4. Scale up. No registration needed, the linked device account comes back with the volume.
5. Check alert delivery as in Path A, step 4.

If the backup is older than the loss, alert delivery works but with stale
registration state. Test before you rely on it.
