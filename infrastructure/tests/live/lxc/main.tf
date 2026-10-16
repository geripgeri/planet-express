# Live-tier harness for the lxc catalog. Deploys ONE tiny throwaway guest
# on the reserved test vmid range, asserts it came up, tears down again.
# Runs only on the self-hosted runner (needs the real Proxmox API).

terraform {
  required_version = ">= 1.12.5"

  # No version pin here: the catalog
  # (infrastructure/catalogs/public/lxc/main.tf) is the tracked pin source,
  # and init resolves one version for the whole tree. The vm harness
  # drifted once this way (random 3.9.0 vs the catalog's 3.9.1) and broke
  # the live run; the ignore below silences the rule for the same reason.
  # tflint-ignore: terraform_required_providers
  required_providers {
    # tflint-ignore: terraform_required_providers
    proxmox = {
      source = "telmate/proxmox"
    }
    # tflint-ignore: terraform_required_providers
    null = {
      source = "opentofu/null"
    }
  }
}

variable "pm_api_url" {
  description = "Proxmox API base URL, e.g. https://192.0.2.1:8006/"
  type        = string
}

variable "pm_api_token_id" {
  description = "API token id of the restricted ci-runner@pve user"
  type        = string
}

variable "pm_api_token_secret" {
  description = "API token secret of the restricted ci-runner@pve user"
  type        = string
  sensitive   = true
}

variable "pm_target_node" {
  description = "Proxmox node that hosts the test guests"
  type        = string
}

variable "pm_bridge" {
  description = "Bridge the test guests attach to"
  type        = string
  default     = "vmbr0"
}

variable "lxc_ostemplate" {
  description = "Volume path of the Debian LXC template. Null uses the Renovate-managed pin in ansible/roles/proxmox_base/defaults/main.yaml; set only to test another template."
  type        = string
  default     = null
}

locals {
  # Single source of truth: the Renovate-managed Ansible pin, read the same way
  # infrastructure/units/public/proxmox/base.hcl reads it for every unit. A
  # copy here drifted once already (12.7 vs 12.12) and Renovate cannot see it.
  ansible_defaults = yamldecode(file("../../../../ansible/roles/proxmox_base/defaults/main.yaml"))

  ostemplate = coalesce(
    var.lxc_ostemplate,
    "local:vztmpl/${local.ansible_defaults.proxmox_base_pveam_template}",
  )
}

provider "proxmox" {
  pm_api_url          = var.pm_api_url
  pm_api_token_id     = var.pm_api_token_id
  pm_api_token_secret = var.pm_api_token_secret
  pm_tls_insecure     = true # self-signed cert until replaced, see base.hcl
}

module "under_test" {
  source = "../../../catalogs/public/lxc"

  proxmox = {
    api_url          = var.pm_api_url
    api_token_id     = var.pm_api_token_id
    api_token_secret = var.pm_api_token_secret
    node_name        = var.pm_target_node
  }

  containers = {
    "tftest-live-lxc" = {
      vmid      = 5900
      cores     = 1
      memory    = 512
      disk_size = "2G"
      network = {
        bridge = var.pm_bridge
        ip     = "dhcp"
        tag    = 20
      }
      tags = "ci;tftest"
    }
  }

  container_details = {
    target_node     = var.pm_target_node
    ostemplate      = local.ostemplate
    storage         = "local-lvm"
    nameserver      = "192.0.2.53"
    unprivileged    = true
    ssh_public_keys = ""
    start           = true
    onboot          = false
  }
}

# The sweep reads ONLY /pools/ci-tests members, and telmate never places a
# created guest into a pool, so a missed teardown would stay invisible forever.
# Enrol the guest on create. PVE implements no POST on /pools/{poolid};
# the write there is a PUT whose vms parameter takes plain VMIDs.
# Pool.Allocate on /pool/ci-tests covers it, and the token already holds
# VM.Allocate from creating the guest.
resource "null_resource" "enroll_in_ci_tests_pool" {
  triggers = {
    vmid = module.under_test.vmids["tftest-live-lxc"]
  }

  provisioner "local-exec" {
    command = <<-EOT
      python3 -c '
      import sys, ssl, urllib.parse, urllib.request
      base, vmid, tid, sec = sys.argv[1:]
      req = urllib.request.Request(
          base.rstrip("/") + "/api2/json/pools/ci-tests",
          data=urllib.parse.urlencode({"vms": vmid}).encode(),
          headers={"Authorization": "PVEAPIToken=" + tid + "=" + sec},
          method="PUT",
      )
      with urllib.request.urlopen(req, timeout=30, context=ssl._create_unverified_context()) as resp:
          resp.read()
      ' "${trim(trimsuffix(trim(var.pm_api_url, "/"), "/api2/json"), "/")}" "${module.under_test.vmids["tftest-live-lxc"]}" "$PM_TOKEN_ID" "$PM_TOKEN_SECRET"
    EOT
    environment = {
      PM_TOKEN_ID     = var.pm_api_token_id
      PM_TOKEN_SECRET = var.pm_api_token_secret
    }
  }
}
