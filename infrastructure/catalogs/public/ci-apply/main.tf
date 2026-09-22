terraform {
  required_version = ">= 1.12.5"

  required_providers {
    kubernetes = {
      source  = "opentofu/kubernetes"
      version = "3.2.1"
    }
  }
}

# CI apply identity for the tofu-apply workflow. Grants the runner
# cluster-admin: the workflow applies the exact plan binaries produced by
# the matching tofu-plan run, so it needs the same reach as a host apply.
# Merge to main is the approval gate (runbook: CI apply identity).
#
# Host-applied only: the cluster is reached through the host's talosctl
# admin kubeconfig. Keeping the apply host-side avoids the runner holding
# the rights to change its own access.

# ci-plan creates the ci-system namespace. Apply the ci-plan unit first.
data "kubernetes_namespace_v1" "ci_system" {
  metadata {
    name = local.ci_namespace
  }
}

resource "kubernetes_service_account_v1" "ci_apply" {
  metadata {
    name      = local.ci_sa_name
    namespace = data.kubernetes_namespace_v1.ci_system.metadata[0].name
  }
}

# k8s 1.24+ no longer issues a token Secret for ServiceAccounts on demand.
# The controller populates data.token and data.ca.crt from the SA annotation.
resource "kubernetes_secret_v1" "ci_apply_token" {
  metadata {
    name      = "${local.ci_sa_name}-token"
    namespace = data.kubernetes_namespace_v1.ci_system.metadata[0].name
    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account_v1.ci_apply.metadata[0].name
    }
  }
  type = "kubernetes.io/service-account-token"
}

resource "kubernetes_cluster_role_binding_v1" "cluster_admin" {
  metadata {
    name = "${local.ci_sa_name}:cluster-admin"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.ci_apply.metadata[0].name
    namespace = kubernetes_service_account_v1.ci_apply.metadata[0].namespace
  }
}
