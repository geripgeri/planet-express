variable "cilium_version" {
  type        = string
  default     = "1.17.6"
  description = "Cilium Helm chart version. Renovate tracks this via custom regex on this file."
}

variable "k8s_service_host" {
  type        = string
  description = "Kubernetes API server host (controller IP) for Cilium k8sServiceHost. Sourced from secrets.yaml via the unit's network_config or dependency outputs."
}

variable "native_routing_cidr" {
  type        = string
  description = "Pod-to-pod native routing CIDR for Cilium (ipv4NativeRoutingCIDR). Provisioned from the export-ignored private config so no internal address is published on the public mirror."
}

variable "helm_values_override" {
  type        = any
  default     = {}
  description = "Optional Helm values override merged on top of the Talos defaults (secrets.yaml or unit inputs)."
}
