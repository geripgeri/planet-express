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
  }
}

locals {
  # Minimal Helm values for Cilium on Talos with cni: none and proxy disabled.
  # Sensitive network topology (pools, L2 interfaces, VLAN IDs) stays in
  # kubernetes/infrastructure/private/network (export-ignored). This chart
  # install only brings the DaemonSet/BPF so nodes move Ready; pools are
  # applied later via the cilium-network ArgoCD Application (private/network).
  helm_values = {
    k8sServiceHost = var.k8s_service_host
    k8sServicePort = 6443

    kubeProxyReplacement = true

    # Talos mounts cgroupv2 at /run/cilium/cgroupv2 and does not automount
    # inside the Cilium Agent container; required on Talos 1.13+ / Cilium 1.17+.
    cgroup = {
      automount = {
        enabled = false
      }
      hostRoot = "/run/cilium/cgroupv2"
    }

    ipam = {
      mode = "kubernetes"
    }

    # Network devices — must match the Talos machine config (vlan20_interface.tfmpl):
    # ens18 = VLAN 10 (DHCP, default route), ens19 = VLAN 20 (static, LB pool).
    devices             = ["ens18", "ens19"]
    directRoutingDevice = "ens18"

    # L2 announcements — required for CiliumLoadBalancerIPPool IPs
    # to be announced on the VLAN 20 interface (ens19).
    l2announcements = { enabled = true }
    externalIPs     = { enabled = true }

    # Native routing mode — required for node-to-node traffic on VLAN 10.
    # Value is not a literal here: it is provisioned from the export-ignored
    # private config (infrastructure/units/private/cilium-network.hcl) so no
    # internal address appears in any path the public mirror publishes.
    ipv4NativeRoutingCIDR = var.native_routing_cidr
    routingMode           = "native"
    autoDirectNodeRoutes  = true

    # Disable masquerading — Talos handles NAT; BPF masquerading
    # conflicts with the MikroTik network topology.
    bpf = {
      masquerade = false
    }
    enableIPv4Masquerade = false

    # Talos hardens bounding caps: SYS_MODULE not in allowed set, so the
    # chart default cleanCiliumState (NET_ADMIN,SYS_MODULE,SYS_ADMIN,SYS_RESOURCE)
    # fails with "unable to apply caps: operation not permitted" on the
    # clean-cilium-state init. Drop SYS_MODULE from the two containers that
    # request it; cilium-agent also drops it for the same reason (BPF already
    # mounted via mount-bpf-fs privileged init).
    securityContext = {
      capabilities = {
        ciliumAgent      = ["CHOWN", "KILL", "NET_ADMIN", "NET_RAW", "IPC_LOCK", "SYS_ADMIN", "SYS_RESOURCE", "DAC_OVERRIDE", "FOWNER", "SETGID", "SETUID"]
        cleanCiliumState = ["NET_ADMIN", "SYS_ADMIN", "SYS_RESOURCE"]
      }
    }

    # The chart renders a GatewayClass when the CRD exists and
    # gatewayClass.create defaults to "auto". On clusters where the
    # GatewayClass is already managed by ArgoCD (private/network/
    # gatewayclass-cilium.yaml), Helm would try to import the existing
    # object and fail with "cannot be imported into the current release".
    # Disable chart-side creation; ArgoCD owns the GatewayClass.
    gatewayAPI = {
      enabled = true
      gatewayClass = {
        create = "false"
      }
    }

    operator = {
      replicas = 1
    }

    # Hubble disabled by default for the bootstrap; enable via var if needed.
    hubble = {
      relay = {
        enabled = false
      }
      ui = {
        enabled = false
      }
    }
  }
}

resource "helm_release" "cilium" {
  name             = "cilium"
  repository       = "https://helm.cilium.io"
  chart            = "cilium"
  version          = var.cilium_version
  namespace        = "kube-system"
  create_namespace = false
  timeout          = 600
  wait             = true
  wait_for_jobs    = true

  values = [
    yamlencode(merge(local.helm_values, var.helm_values_override))
  ]
}
