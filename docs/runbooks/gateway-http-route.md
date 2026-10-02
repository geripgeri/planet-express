# Runbook: Adding a Gateway API HTTP Route

Publish an application through the shared wildcard gateway. Every app that needs
an ingress path uses this procedure. The result is two manifests: one
`HTTPRoute` and one ArgoCD `Application` that keeps it in sync.

## How routing works here

One Gateway serves every subdomain. It lives in `kube-system` and is named
`shared-gateway`. It has two listeners:

| Listener | Port | Protocol | Hostname        | TLS                      |
| -------- | ---- | -------- | --------------- | ------------------------ |
| `http`   | 80   | HTTP     | wildcard domain | none                     |
| `https`  | 443  | HTTPS    | wildcard domain | wildcard cert, Terminate |

Consequences that shape every route you write:

- TLS terminates at the gateway. Your `HTTPRoute` carries **no `tls` stanza**.
  Rules NET-01, NET-02 and [ADR-005](../decisions/ADR-005-cilium-gateway-api.md) govern this.
- The gateway allows routes from any namespace, so a `parentRef` to
  `shared-gateway` in `kube-system` works from any app namespace without a
  `ReferenceGrant`. `allowedRoutes` covers the parent; a `ReferenceGrant` is
  only needed for a cross-namespace `backendRef`.
- The backend `Service` must be in the **same namespace as the route**. That is
  why each app gets its own route directory instead of one shared file.

## Decide three things first

1. **Does the app already run in the cluster?** Find the `Service` name and the
   port. Do not guess. Render the chart and read the `Service`:

   ```bash
   docker run --rm --network host --entrypoint sh alpine/helm:3.14.0 -c \
     "helm repo add <repo> <chart-url> >/dev/null 2>&1 && \
      helm template <release> <repo>/<chart> --version <version> <same-values> \
      | grep -A12 '^  name: <service-name>$'"
   ```

   Pass the same values the real release uses. A route that points at a port
   that only exists under a different value combination fails at request time,
   not at apply time.

2. **Which listener?** Use `sectionName: https` unless you have a reason not
   to. It serves only the TLS listener. A route with no `sectionName` attaches
   to every listener, which also puts it on plain HTTP with no redirect to
   HTTPS. The three routes in the repo all pin `https`.

3. **Does the app sit behind Authentik?** Rule AUTH-01 forbids exposing a
   service with neither OIDC nor forward auth. Native OIDC apps configure the
   provider in OpenTofu. Apps without OIDC need an `ExtensionRef` forward-auth
   filter on the route. Confirm which case you are in before shipping.

## File layout

Route directories live under `private/`, because each manifest carries a live
hostname and `AGENTS.md` forbids real hostnames in the public tree. The mirror
strips `private/`, which is the intended outcome. See [ADR-021](../decisions/ADR-021-public-mirror-privacy-partitioning.md).

```
kubernetes/infrastructure/private/<app>-route/kustomization.yaml
kubernetes/infrastructure/private/<app>-route/httproute.yaml
kubernetes/infrastructure/private/apps/<app>-route.yaml
```

`private/apps/` holds one ArgoCD `Application` per managed unit. That is the
convention, and it is not yet written down in an ADR.

### Use a kustomization, not a `directory` source

Write `kustomization.yaml` and let the `Application` use a plain `path`. The
alternative seen in the tree today, a `directory` source with `recurse: true`,
has two costs:

- **kustomize never runs.** A `directory` source bypasses the kustomize build
  entirely. The ArgoCD Helm release sets kustomize build options for the ksops
  exec plugin. Without a kustomize build, a sops-encrypted manifest in that
  directory is applied as ciphertext.
- **`recurse: true` applies everything.** A stray file, a backup copy, a
  dropped secret is applied without review. A kustomization applies only the
  resources it lists, and ignores the rest.

Cost of the kustomization: one more small file. Worth it.

## The HTTPRoute

```yaml
# HTTPRoute exposing <APP> via the shared wildcard gateway.
# Cross-namespace parentRef is valid because the gateway allows routes From All.
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: <app>
  namespace: <app-namespace>
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  parentRefs:
    - name: shared-gateway
      namespace: kube-system
      sectionName: https
  hostnames:
    - <app>.<your-domain>
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: <backend-service>
          port: <port>
```

Sync wave 1 lets the route land after the backend. A route that sorts before
its `Service` reports a failing backend until the `Service` appears.

## The Application

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: <app>-route
  namespace: argocd
spec:
  project: default
  source:
    repoURL: <your-git-remote-url>
    targetRevision: main
    path: kubernetes/infrastructure/private/<app>-route
  destination:
    server: https://kubernetes.default.svc
    namespace: <app-namespace>
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=false
```

- `CreateNamespace=false` unless the app namespace genuinely does not exist
  yet. Set it to `true` only when the route creates the namespace.
- **No `sources` chart entry** when the app is already deployed by Terragrunt or
  by hand. A chart source is only needed when ArgoCD owns the app itself. The
  ArgoCD and longhorn Applications differ here: longhorn's carries a chart
  source because ArgoCD deploys Longhorn, while the ArgoCD route's does not
  because Terragrunt deploys ArgoCD.
- `targetRevision: main` and a single `source` need no placeholder token. The
  authentik applications still use one, filled by the bootstrap script. If you
  copy that file, check whether the script's app list covers your file, or the
  placeholder is shipped unresolved.

## Steps

1. Create the route directory and both manifests.
2. Add a DNS record for the hostname pointing at the gateway load balancer
   address. **This is a provider change, not a git change.** A route with no
   record is dead.
3. Validate: `uv run pre-commit run --files <the three files>`. `kubeconform`
   and `gitleaks` both gate the commit.
4. Commit and get the branch merged. Merging to `main` is what makes the
   `Application` appear, because `root` reads `main`.
5. Confirm `root` adopted it, then verify on the cluster.

## Verify

```bash
kubectl get httproute -n <app-namespace> <app> -o json \
  | jq '.status.parents[0].conditions[] | select(.type=="Accepted")'
kubectl get gateway -n kube-system shared-gateway
```

`Accepted: True` with reason `Accepted` means the gateway took the route. Then
load the hostname in a browser. A route that is `Accepted` but returns 503
means the `Service` name or port is wrong, not that the route is broken.

## The Application is picked up automatically

**No bootstrap step. Do not apply the `Application` by hand.**

An ArgoCD `Application` named `root` is the app-of-apps. Its source is the
`private/apps/` directory itself, with `directory: {recurse: true}`, on
`main`. Every file you drop in that directory becomes an `Application` on the
next sync of `root`. That is how the authentik, longhorn and argocd route
Applications all came to exist.

Confirm your new Application was adopted:

```bash
kubectl get application -n argocd root \
  -o jsonpath='{.status.resources[*].name}{"\n"}'
```

Your Application name must appear in that list. If it does not, `root` will
prune it on its next sync, because a missing manifest is a resource that
`root` believes it should delete. It typically does not appear if the file is
not a valid `Application` manifest, or if the file is not committed to `main`
yet.

Do not use these two signals, both are dead ends:

- **`metadata.ownerReferences`** is empty on every Application in the fleet,
  including adopted children. ArgoCD's app-of-apps does not set owner
  references.
- **The `argocd.argoproj.io/instance` label** is empty on every Application in
  the fleet, including the ones `root` demonstrably manages.

`root.status.resources` is the only reliable answer.

### Why `root` uses `directory: recurse` and route dirs should not

This looks like it contradicts the kustomization rule above. It does not, and
the difference is worth keeping straight:

|                  | `root` source                                             | Route directory source                         |
| ---------------- | --------------------------------------------------------- | ---------------------------------------------- |
| Path             | `private/apps/`                                           | `private/<app>-route/`                         |
| Holds            | flat, single-document `Application` manifests             | route manifests, possibly sops-encrypted later |
| Kustomize needed | no, nothing to decrypt                                    | yes, for the ksops plugin                      |
| Stray file cost  | the file is treated as an `Application` and fails to sync | the file is applied unreviewed                 |

`root`'s directory holds only `Application` manifests, so `recurse: true` is
cheap there. Two consequences still apply: anything you drop into
`private/apps/` is interpreted as an `Application` manifest, and deleting a
manifest from that directory makes `root` delete the corresponding Application
in the cluster.

## Traps

- **Do not guess the backend port.** Chart values decide it. A port that exists
  only in a different values combination passes `kubectl apply` and fails every
  request.
- **`parentRef` needs `namespace: kube-system` explicitly.** Without it the ref
  resolves to a Gateway in the route's own namespace, which does not exist, and
  the route stays detached with no error at apply time.
- **`sectionName: https` means no HTTP.** Anything that links to the plain HTTP
  URL gets a connection failure, not a redirect.
- **The bootstrap script fills `__GITEA_REPO_URL__` only for the files in its
  app list.** A new file using that token ships the token itself.
- **A stale checkout misleads you.** Manifests under `private/` are absent from
  a filtered clone, so a missing file may mean a stale tree rather than a
  missing commit. Confirm against the real branch before concluding a manifest
  was never written.
- **A `STRIPPED` line in a sandbox export report is not a lost file.** It is the
  publication verdict: the path is already covered by `export-ignore` and will
  not reach the public mirror. Verify by listing the exported bundle's tree, not
  by reading the report.
- **An unadopted Application gets pruned.** If your `Application` does not show
  up in `root.status.resources`, the next sync of `root` deletes it, because a
  manifest that is absent looks like a resource that should not exist. Check the
  adoption list before assuming the route is deploying.
- **Anything in `private/apps/` is treated as an `Application` manifest.** That
  directory is the `root` source. A stray file there does not get ignored, it
  fails the sync.

## Existing routes

| App       | Route namespace   | Backend service     | Deployed by         |
| --------- | ----------------- | ------------------- | ------------------- |
| argocd    | `argocd`          | `argocd-server`     | Terragrunt          |
| authentik | `authentik`       | `authentik-server`  | Terragrunt          |
| longhorn  | `longhorn-system` | `longhorn-frontend` | ArgoCD chart source |

Read the live hostnames and backends from the manifests under `private/`, not
from this table.
