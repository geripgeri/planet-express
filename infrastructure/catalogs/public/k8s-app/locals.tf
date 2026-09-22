# In-cluster Kubernetes API server URL. ArgoCD Applications use it as the
# destination cluster ("deploy here, where ArgoCD runs").
locals {
  cluster_server = "https://kubernetes.default.svc"

  argocd_finalizer = "resources-finalizer.argocd.argoproj.io"
}
