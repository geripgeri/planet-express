terraform {
  required_version = ">= 1.12.5"

  required_providers {
    kubernetes = {
      source  = "opentofu/kubernetes"
      version = "3.0.1"
    }
  }
}

# CI plan-only identity for the infra-testing workflow. Grants the runner
# just enough read access to plan the argocd stack (and nothing else):
# namespaces cluster-wide, Secrets inside argocd/cert-manager, and
# argoproj.io Applications inside argocd. No write verbs anywhere.
#
# Host-applied only: the cluster is reached through the host's talosctl
# admin kubeconfig, and the credentials this unit provisions are the very
# thing CI needs to plan. Keeping the apply host-side avoids the runner
# holding the rights to change its own access (runbook: CI plan identity).

resource "kubernetes_namespace_v1" "ci_system" {
  metadata {
    name = "ci-system"
  }
}

resource "kubernetes_service_account_v1" "ci_plan" {
  metadata {
    name      = "ci-plan"
    namespace = kubernetes_namespace_v1.ci_system.metadata[0].name
  }
}

# k8s 1.24+ no longer issues a token Secret for ServiceAccounts on demand.
# The controller populates data.token and data.ca.crt from the SA annotation.
resource "kubernetes_secret_v1" "ci_plan_token" {
  metadata {
    name      = "ci-plan-token"
    namespace = kubernetes_namespace_v1.ci_system.metadata[0].name
    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account_v1.ci_plan.metadata[0].name
    }
  }
  type = "kubernetes.io/service-account-token"
}

resource "kubernetes_cluster_role_v1" "namespace_read" {
  metadata {
    name = "ci-plan:namespaces-read"
  }
  rule {
    api_groups = [""]
    resources  = ["namespaces"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "namespace_read" {
  metadata {
    name = "ci-plan:namespaces-read"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.namespace_read.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.ci_plan.metadata[0].name
    namespace = kubernetes_service_account_v1.ci_plan.metadata[0].namespace
  }
}

# Discovery endpoints the kubernetes/helm/kubectl providers query when the
# argocd catalog connects to the cluster.
resource "kubernetes_cluster_role_binding_v1" "discovery" {
  metadata {
    name = "ci-plan:discovery"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "system:discovery"
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.ci_plan.metadata[0].name
    namespace = kubernetes_service_account_v1.ci_plan.metadata[0].namespace
  }
}

# Read access inside the namespaces the argocd stack manages: helm release
# state and the connection/dns01/sops inputs are Secrets; the root
# Application is an argoproj.io resource. These namespaces must already
# exist (apply the argocd stack first).
resource "kubernetes_role_v1" "argocd_read" {
  metadata {
    name      = "ci-plan:argocd"
    namespace = "argocd"
  }
  rule {
    api_groups = [""]
    resources  = ["secrets"]
    verbs      = ["get", "list", "watch"]
  }
  rule {
    api_groups = ["argoproj.io"]
    resources  = ["applications"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_role_binding_v1" "argocd_read" {
  metadata {
    name      = "ci-plan:argocd"
    namespace = "argocd"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.argocd_read.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.ci_plan.metadata[0].name
    namespace = kubernetes_service_account_v1.ci_plan.metadata[0].namespace
  }
}

resource "kubernetes_role_v1" "cert_manager_read" {
  metadata {
    name      = "ci-plan:cert-manager"
    namespace = "cert-manager"
  }
  rule {
    api_groups = [""]
    resources  = ["secrets"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_role_binding_v1" "cert_manager_read" {
  metadata {
    name      = "ci-plan:cert-manager"
    namespace = "cert-manager"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.cert_manager_read.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.ci_plan.metadata[0].name
    namespace = kubernetes_service_account_v1.ci_plan.metadata[0].namespace
  }
}
