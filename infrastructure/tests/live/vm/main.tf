# Live-tier harness for the proxmox-vm catalog. Boots one minimal VM on a
# reserved vmid (no ISO: this proves catalog wiring, not guest OS health).

terraform {
  required_version = ">= 1.12.5"

  # No version pin here: the catalog
  # (infrastructure/catalogs/public/proxmox-vm/main.tf) is the tracked pin
  # source, and init resolves one version for the whole tree. A duplicate
  # pin drifted once (random 3.9.0 vs the catalog's 3.9.1) and broke the
  # live run; the ignore below silences the rule for the same reason.
  # tflint-ignore: terraform_required_providers
  required_providers {
    # tflint-ignore: terraform_required_providers
    proxmox = {
      source = "telmate/proxmox"
    }
    # tflint-ignore: terraform_required_providers
    random = {
      source = "opentofu/random"
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

provider "proxmox" {
  pm_api_url          = var.pm_api_url
  pm_api_token_id     = var.pm_api_token_id
  pm_api_token_secret = var.pm_api_token_secret
  pm_tls_insecure     = true
}

module "under_test" {
  source = "../../../catalogs/public/proxmox-vm"

  proxmox = {
    api_url          = var.pm_api_url
    api_token_id     = var.pm_api_token_id
    api_token_secret = var.pm_api_token_secret
    node_name        = var.pm_target_node
  }

  vms = {
    "tftest-live-vm" = {
      disk_capacity            = "4G"
      additional_disk_capacity = null
      name                     = null
      vmid                     = 5901
      # A leftover guest on this reserved vmid is recycled (telmate adopts and
      # reconfigures it) instead of aborting with "vmId already in use".
      force_create = true
      # telmate 3.0.2-rc07+ rejects the "" that the catalog maps a null
      # macaddr to, so the fixture pins a valid address.
      macaddr                 = "bc:24:11:2a:3b:4c"
      vmodel                  = "virtio"
      vnetwork                = var.pm_bridge
      additional_vnetwork     = null
      vnetwork_tag            = null
      additional_vnetwork_tag = null
      vcores                  = 1
      vram                    = 1024
      tags                    = "ci;tftest"
    }
  }

  vm_details = {
    agent_number       = 0
    socket_number      = 1
    cpu_type           = "kvm64"
    scsihw             = "virtio-scsi-pci"
    qemu_os            = "other"
    target_node        = var.pm_target_node
    start_at_node_boot = false
    iso_name           = null
    storage            = "local-lvm"
    ipconfig           = "ip=dhcp"
    nameserver         = "192.0.2.53"
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
    vmid = module.under_test.vmids["tftest-live-vm"]
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
      ' "${trim(trimsuffix(trim(var.pm_api_url, "/"), "/api2/json"), "/")}" "${module.under_test.vmids["tftest-live-vm"]}" "$PM_TOKEN_ID" "$PM_TOKEN_SECRET"
    EOT
    environment = {
      PM_TOKEN_ID     = var.pm_api_token_id
      PM_TOKEN_SECRET = var.pm_api_token_secret
    }
  }
}
