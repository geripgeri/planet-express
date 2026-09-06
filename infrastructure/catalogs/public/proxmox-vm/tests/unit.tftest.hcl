# Unit tier for the proxmox-vm catalog: mocked provider, zero credentials.
# Real-boot coverage lives in infrastructure/tests/live/vm/.

mock_provider "proxmox" {}

variables {
  proxmox = {
    api_url          = "https://192.0.2.1:8006/"
    api_token_id     = "ci-runner@pve!tftest"
    api_token_secret = "mock-only-not-a-secret"
    node_name        = "zoidberg"
  }

  vms = {
    "tftest-unit-vm" = {
      disk_capacity            = "4G"
      additional_disk_capacity = null
      name                     = null
      vmid                     = 5901
      # Provider plan validation rejects the empty-string fallback that
      # main.tf sends when macaddr is null, so tests supply a valid address.
      macaddr                 = "bc:24:11:2a:3b:4c"
      vmodel                  = "virtio"
      vnetwork                = "vmbr0"
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
    target_node        = "zoidberg"
    start_at_node_boot = false
    iso_name           = null
    storage            = "local-lvm"
    ipconfig           = "ip=dhcp"
    nameserver         = "192.0.2.53"
  }
}

run "vmid_output_maps_key_to_configured_vmid" {
  command = plan

  assert {
    condition     = output.vmids["tftest-unit-vm"] == 5901
    error_message = "vmids output must map each vm key to its configured vmid"
  }
}

run "ip_output_contains_every_input_key" {
  command = plan

  # default_ipv4_address is provider-computed, hence unknown under mocks;
  # assert the key mapping shape instead of the value.
  assert {
    condition     = contains(keys(output.ip_addresses), "tftest-unit-vm")
    error_message = "ip_addresses output must contain an entry for every vm key"
  }
}
