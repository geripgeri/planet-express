output "cilium_version" {
  value       = var.cilium_version
  description = "Installed Cilium chart version"
}

output "k8s_service_host" {
  value       = var.k8s_service_host
  description = "API server host used for k8sServiceHost"
}
