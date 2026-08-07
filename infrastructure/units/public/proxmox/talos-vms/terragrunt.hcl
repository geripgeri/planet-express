locals {
  secret_vars  = yamldecode(sops_decrypt_file(find_in_parent_folders("secrets.yaml")))
  worker_count = 3

  worker_defaults = {
    disk_capacity            = "15G"
    additional_disk_capacity = "100G"
    vcores                   = 4
    vram                     = 4096
    tags                     = "talos,worker"
    vmodel                   = "virtio"
    vnetwork                 = "vmbr0"
    vnetwork_tag             = 20
    additional_vnetwork      = "vmbr0"
  }

  workers = {
    for i in range(1, local.worker_count + 1) :
    format("talos-worker-%02d", i) => merge(local.worker_defaults, {
      vmid    = 500 + i
      macaddr = format("AA:BB:CC:DD:05:%02X", i)
    })
  }
}

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}//infrastructure/catalogs/public/proxmox-vm"
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
provider "proxmox" {
  pm_api_url          = var.proxmox.api_url
  pm_api_token_id     = var.proxmox.api_token_id
  pm_api_token_secret = var.proxmox.api_token_secret
  pm_tls_insecure     = true # TODO change this after replacing the self-signed SSL cert.
}
EOF
}

inputs = {
  proxmox = local.secret_vars.proxmox

  vm_details = {
    agent_number       = 1
    socket_number      = 1
    cpu_type           = "x86-64-v2-AES"
    scsihw             = "virtio-scsi-pci"
    qemu_os            = "l26"
    target_node        = local.secret_vars.proxmox.node_name
    start_at_node_boot = true
    iso_name           = "local:iso/talos-linuxnocloud-amd64.iso"
    storage            = "local-lvm"
    ipconfig           = "ip=dhcp"
    nameserver         = join(" ", local.secret_vars.network_config.vlan-10.public-nameservers-only)
  }

  vms = merge(
    {
      talos-controller-01 = {
        disk_capacity       = "10G"
        vmid                = 500
        macaddr             = "AA:BB:CC:DD:05:00"
        vcores              = 2
        vram                = 2048
        tags                = "talos,controller"
        vmodel              = "virtio"
        vnetwork            = "vmbr0"
        vnetwork_tag        = 20
        additional_vnetwork = "vmbr0"
      }
    },
    local.workers
  )
}
