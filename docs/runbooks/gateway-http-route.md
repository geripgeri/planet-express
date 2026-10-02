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
4. Commit and get the branch merged.
5. Bootstrap the `Application`, if the fleet needs it. See below.
6. Verify on the cluster.

## Verify

```bash
kubectl get httproute -n <app-namespace> <app> -o json \
  | jq '.status.parents[0].conditions[] | select(.type=="Accepted")'
kubectl get gateway -n kube-system shared-gateway
```

`Accepted: True` with reason `Accepted` means the gateway took the route. Then
load the hostname in a browser. A route that is `Accepted` but returns 503
means the `Service` name or port is wrong, not that the route is broken.

## Bootstrap the Application

An ArgoCD `Application` cannot create itself, so the first one needs an
external apply. Determine how the existing ones get bootstrapped before
relying on it:

```bash
kubectl get applicationset -n argocd -o name
kubectl get application -n argocd authentik-route -o jsonpath='{.metadata.ownerReferences}'
```

An `ownerReferences` entry means an app-of-apps owns it and the fleet picks up
new files in `private/apps/` on its own. No owner means each `Application` was
applied by hand, and yours needs the same one-time apply:

```bash
kubectl apply -f kubernetes/infrastructure/private/apps/<app>-route.yaml
```

Record which of the two applies in this runbook once you know. It is the one
step in this procedure that is not yet written down anywhere.

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

## Existing routes

| App       | Route namespace   | Backend service     | Deployed by         |
| --------- | ----------------- | ------------------- | ------------------- |
| authentik | `authentik`       | `authentik-server`  | Terragrunt          |
| longhorn  | `longhorn-system` | `longhorn-frontend` | ArgoCD chart source |
| argocd    | `argocd`          | `argocd-server`     | Terragrunt          |

Read the live hostnames and backends from the manifests under `private/`, not
from this table.
