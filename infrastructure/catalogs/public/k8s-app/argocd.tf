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
  version          = "9.4.3"
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
    })
  ]

  depends_on = [kubernetes_namespace_v1.argocd]
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

  depends_on = [helm_release.argocd]
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
      finalizers = ["resources-finalizer.argocd.argoproj.io"]
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
        server    = "https://kubernetes.default.svc"
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
