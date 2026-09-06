variable "gitea" {
  type = object({
    url      = string
    username = string
    token    = string
  })
  sensitive   = true
  description = "Read-only connection details for the internal Gitea monorepo ArgoCD tracks"
}

variable "dns01_api_token" {
  type        = string
  sensitive   = true
  description = "DNS provider API token with Zone.DNS edit permission, used by the cert-manager DNS-01 solver"
}

variable "sops_age_key" {
  type        = string
  sensitive   = true
  default     = ""
  description = "SOPS age private key injected into the cluster for future ksops use; sourced from SOPS_AGE_KEY at apply time, never stored in git"
}

variable "target_revision" {
  type        = string
  default     = "main"
  description = "Git revision of the monorepo the root Application tracks"
}
