variable "authentik_url" {
  description = "Base URL of the Authentik instance (secrets.yaml authentik.url)"
  type        = string
}

variable "argocd_callback_url" {
  description = "ArgoCD OAuth callback URL from secrets.yaml"
  type        = string
}
