# Retrieve the Kubeconfig of the cluster
output "kubeconfig" {
  value       = resource.talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive   = true
  description = "The raw kubeconfig content for accessing the Talos Kubernetes cluster."
}

# Retrieve the Client Configuration for the Talos Cluster
output "client_configuration" {
  value       = data.talos_client_configuration.this.client_configuration
  sensitive   = true
  description = "The client configuration required to authenticate with the Talos cluster via talosctl."
}

# Retrieve the full Talos configuration for talosctl interaction
output "talos_configuration" {
  value       = data.talos_client_configuration.this.talos_config
  sensitive   = true
  description = "The complete Talos configuration file content, useful for initializing talosctl contexts."
}

output "controller_installer_image" {
  value       = data.talos_image_factory_urls.controller.urls.installer
  description = "The installer image URL for Talos control plane nodes."
}

output "worker_installer_image" {
  value       = data.talos_image_factory_urls.worker.urls.installer
  description = "The installer image URL for Talos worker nodes."
}
