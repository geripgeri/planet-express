# The token Controller fills data.token asynchronously after the Secret is
# created. If `terragrunt output` on the freshly applied unit yields an
# empty token, re-run it a few seconds later (refresh) before storing the
# kubeconfig.
data "kubernetes_secret_v1" "ci_plan_token" {
  metadata {
    name      = kubernetes_secret_v1.ci_plan_token.metadata[0].name
    namespace = kubernetes_secret_v1.ci_plan_token.metadata[0].namespace
  }
  depends_on = [kubernetes_secret_v1.ci_plan_token]
}

output "api_server" {
  description = "Kubernetes API endpoint used by the CI kubeconfig"
  value       = var.api_server
}

output "kubeconfig" {
  description = "Base64 CI kubeconfig (context admin@talos-cluster-01); paste into the Gitea KUBECONFIG secret"
  sensitive   = true
  value = base64encode(<<-EOF
    apiVersion: v1
    kind: Config
    clusters:
    - name: talos-cluster-01
      cluster:
        certificate-authority-data: ${data.kubernetes_secret_v1.ci_plan_token.data["ca.crt"]}
        server: ${var.api_server}
    contexts:
    - name: admin@talos-cluster-01
      context:
        cluster: talos-cluster-01
        user: ci-plan
        namespace: argocd
    current-context: admin@talos-cluster-01
    users:
    - name: ci-plan
      user:
        token: ${data.kubernetes_secret_v1.ci_plan_token.data["token"]}
  EOF
  )
}
