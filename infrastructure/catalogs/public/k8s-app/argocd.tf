resource "kubernetes_namespace_v1" "argocd" {
  metadata {
    name = "argocd"
  }
}

resource "kubernetes_namespace_v1" "cert_manager" {
  metadata {
    name = "cert-manager"
  }
}

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "9.7.1"
  namespace        = kubernetes_namespace_v1.argocd.metadata[0].name
  create_namespace = false
  timeout          = 1200
  wait             = true
  wait_for_jobs    = true

  values = [
    yamlencode({
      configs = {
        params = {
          # UI/API served plain behind port-forward and, later, the shared
          # Gateway + Authentik forward auth (ADR-005). No TLS termination
          # inside the cluster.
          "server.insecure" = true
        }
        cm = {
          # ksops KRM exec plugin for encrypted kubernetes/ manifests
          # (ADR-021 September 2026 amendment).
          "kustomize.buildOptions" = "--enable-alpha-plugins --enable-exec"
          # Null until secrets.yaml.authentik.argocd_oidc is populated; Helm
          # drops the key and ArgoCD keeps local login only.
          "oidc.config" = var.authentik_oidc == null ? null : jsonencode({
            name            = "Authentik"
            issuer          = var.authentik_oidc.issuer
            clientID        = var.authentik_oidc.client_id
            clientSecret    = var.authentik_oidc.client_secret
            requestedScopes = ["openid", "profile", "email", "groups"]
          })
        }
        rbac = {
          "policy.csv"     = "g, argocd-admins, role:admin\n"
          "policy.default" = "role:readonly"
          "scopes"         = "[groups, email]"
        }
      }
      applicationSet = {
        enabled = true
      }
      dex = {
        enabled = false
      }
      notifications = {
        enabled = false
      }
      repoServer = {
        # ksops install (viaduct-ai/kustomize-sops v4.5.1): init container
        # copies ksops + bundled kustomize into an emptyDir; the age key
        # Secret (kubernetes_secret_v1.sops_age) mounts read-only for
        # in-cluster decryption only.
        env = [
          {
            name  = "XDG_CONFIG_HOME"
            value = "/.config"
          },
          {
            name  = "SOPS_AGE_KEY_FILE"
            value = "/.config/sops/age/keys.txt"
          },
        ]
        initContainers = [
          {
            name    = "ksops-install"
            image   = "viaductoss/ksops:v4.5.1"
            command = ["/usr/local/bin/ksops", "install", "--with-kustomize", "/custom-tools"]
            volumeMounts = [
              {
                name      = "custom-tools"
                mountPath = "/custom-tools"
              },
            ]
          },
        ]
        volumes = [
          {
            name     = "custom-tools"
            emptyDir = {}
          },
          {
            name = "sops-age"
            secret = {
              secretName = "sops-age"
              items = [
                {
                  key  = "sops.age.privatekey"
                  path = "keys.txt"
                },
              ]
            }
          },
        ]
        volumeMounts = [
          {
            name      = "custom-tools"
            mountPath = "/usr/local/bin/ksops"
            subPath   = "ksops"
          },
          {
            name      = "custom-tools"
            mountPath = "/usr/local/bin/kustomize"
            subPath   = "kustomize"
          },
          {
            name      = "sops-age"
            mountPath = "/.config/sops/age"
            readOnly  = true
          },
        ]
        livenessProbe = {
          httpGet = {
            path   = "/healthz"
            port   = "repo-server"
            scheme = "HTTP"
          }
          failureThreshold    = 3
          initialDelaySeconds = 10
          periodSeconds       = 10
          successThreshold    = 1
          timeoutSeconds      = 1
        }
        readinessProbe = {
          httpGet = {
            path   = "/healthz"
            port   = "repo-server"
            scheme = "HTTP"
          }
          failureThreshold    = 3
          initialDelaySeconds = 10
          periodSeconds       = 10
          successThreshold    = 1
          timeoutSeconds      = 1
        }
      }
    })
  ]

  depends_on = [
    kubernetes_namespace_v1.argocd,
    kubernetes_secret_v1.sops_age,
  ]
}

# Repository connection so the root Application can clone the monorepo.
resource "kubernetes_secret_v1" "gitea_repo_creds" {
  metadata {
    name      = "gitea-repo-creds"
    namespace = kubernetes_namespace_v1.argocd.metadata[0].name
    labels = {
      "argocd.argoproj.io/secret-type" = "repository"
    }
  }

  data = {
    url      = var.gitea.url
    username = var.gitea.username
    password = var.gitea.token
  }

  depends_on = [helm_release.argocd]
}

# DNS-01 solver credential for the ClusterIssuer. Lives in the cert-manager
# namespace: ClusterIssuers resolve solver secrets there regardless of where
# the ClusterIssuer object sits.
resource "kubernetes_secret_v1" "dns01_api_token" {
  metadata {
    name      = "dns01-api-token"
    namespace = kubernetes_namespace_v1.cert_manager.metadata[0].name
  }

  data = {
    api-token = var.dns01_api_token
  }
}

# SOPS age key for future in-git encrypted Secrets (ksops). Created only when
# SOPS_AGE_KEY was exported at apply time; absence is not an error.
resource "kubernetes_secret_v1" "sops_age" {
  count = length(var.sops_age_key) > 0 ? 1 : 0

  metadata {
    name      = "sops-age"
    namespace = kubernetes_namespace_v1.argocd.metadata[0].name
  }

  data = {
    "sops.age.privatekey" = var.sops_age_key
  }

  depends_on = [kubernetes_namespace_v1.argocd]
}

# Root App of Apps. Discovers every child Application manifest under
# kubernetes/infrastructure/private/apps. Defined inline so no repo file carries the
# repoURL.
resource "kubectl_manifest" "root_application" {
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name       = "root"
      namespace  = kubernetes_namespace_v1.argocd.metadata[0].name
      finalizers = [local.argocd_finalizer]
    }
    spec = {
      project = "default"
      source = {
        repoURL        = var.gitea.url
        targetRevision = var.target_revision
        # Child Application manifests carry repoURL values (the internal
        # Gitea URL), so they live in the export-ignored tree.
        path = "kubernetes/infrastructure/private/apps"
        directory = {
          recurse = true
        }
      }
      destination = {
        server    = local.cluster_server
        namespace = kubernetes_namespace_v1.argocd.metadata[0].name
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
      }
    }
  })

  depends_on = [
    helm_release.argocd,
    kubernetes_secret_v1.gitea_repo_creds,
  ]
}

# Self-management Application: manages only the config-only directory
# kubernetes/infrastructure/argocd/ (chart release stays in helm_release above).
# Name must be argocd: docs/runbooks/argocd-breakglass.md addresses it as such.
resource "kubectl_manifest" "argocd_self" {
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name       = "argocd"
      namespace  = kubernetes_namespace_v1.argocd.metadata[0].name
      finalizers = [local.argocd_finalizer]
    }
    spec = {
      project = "default"
      source = {
        repoURL        = var.gitea.url
        targetRevision = var.target_revision
        path           = "kubernetes/infrastructure/argocd"
        directory = {
          recurse = true
        }
      }
      destination = {
        server    = local.cluster_server
        namespace = kubernetes_namespace_v1.argocd.metadata[0].name
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
      }
    }
  })

  depends_on = [
    helm_release.argocd,
    kubernetes_secret_v1.gitea_repo_creds,
  ]
}
