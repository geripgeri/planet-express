terraform {
  required_version = ">= 1.12.5"

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "3.1.1"
    }

    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "3.0.1"
    }

    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.19.0"
    }
  }
}

# One-time ArgoCD bootstrap per ADR-003: after this unit applies, ArgoCD
# self-manages everything under kubernetes/ via the root Application below.
# Cilium CNI is the exception: it is provisioned via the dedicated cilium
# catalog/unit (cni: none -> nodes NotReady until DaemonSet runs, so it must
# precede ArgoCD — ADR-005, incident 2026-08-29).
