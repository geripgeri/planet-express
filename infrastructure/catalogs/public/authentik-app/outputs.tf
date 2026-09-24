output "client_id" {
  description = "OAuth2 client id for the ArgoCD Authentik provider"
  value       = authentik_provider_oauth2.argocd.client_id
}

output "client_secret" {
  description = "OAuth2 client secret for the ArgoCD Authentik provider"
  value       = authentik_provider_oauth2.argocd.client_secret
  sensitive   = true
}

output "issuer" {
  description = "OIDC issuer URL for the ArgoCD application in Authentik"
  value       = "${var.authentik_url}/application/o/argocd/"
}
