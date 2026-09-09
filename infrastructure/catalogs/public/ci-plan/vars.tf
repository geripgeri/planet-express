variable "api_server" {
  type        = string
  description = "Kubernetes API endpoint the CI runner reaches, https://<controlplane-ip-or-vip>:6443"
}
