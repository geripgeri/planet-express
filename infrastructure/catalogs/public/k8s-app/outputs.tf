output "namespace" {
  description = "Namespace ArgoCD runs in"
  value       = kubernetes_namespace_v1.argocd.metadata[0].name
}

output "repo_connection_secret" {
  description = "Name of the repository connection Secret consumed by the root Application"
  value       = kubernetes_secret_v1.gitea_repo_creds.metadata[0].name
}
