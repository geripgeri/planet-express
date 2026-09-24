terraform {
  required_version = ">= 1.12.5"

  required_providers {
    authentik = {
      source  = "goauthentik/authentik"
      version = "2026.8.0"
    }
  }
}

# Slice 1 (ADR-008): one OAuth2 provider + application for ArgoCD and the
# group the ArgoCD RBAC maps to role:admin. The provider token that manages
# these resources lives in secrets.yaml (authentik.api_token) and is only
# valid after the Authentik initial-admin bootstrap (runbook).

data "authentik_flow" "explicit_consent" {
  slug = "default-provider-authorization-explicit-consent"
}

data "authentik_flow" "invalidation" {
  slug = "default-provider-invalidation"
}

resource "authentik_provider_oauth2" "argocd" {
  name               = "argocd"
  client_id          = "argocd"
  authorization_flow = data.authentik_flow.explicit_consent.id
  invalidation_flow  = data.authentik_flow.invalidation.id
  allowed_redirect_uris = [
    {
      matching_mode = "strict"
      url           = "http://localhost:8080/callback"
    },
    {
      matching_mode = "strict"
      url           = var.argocd_callback_url
    },
  ]
}

resource "authentik_application" "argocd" {
  name              = "ArgoCD"
  slug              = "argocd"
  protocol_provider = authentik_provider_oauth2.argocd.id
}

resource "authentik_group" "argocd_admins" {
  name = "argocd-admins"
}
