# Unit tier for the lxc catalog: mocked provider, zero credentials, runs on
# any runner. Real-boot coverage lives in infrastructure/tests/live/lxc/.

mock_provider "proxmox" {}

variables {
  proxmox = {
    api_url          = "https://192.0.2.1:8006/"
    api_token_id     = "ci-runner@pve!tftest"
    api_token_secret = "mock-only-not-a-secret"
    node_name        = "zoidberg"
  }

  containers = {
    "tftest-unit-lxc" = {
      vmid      = 5900
      cores     = 1
      memory    = 512
      disk_size = "2G"
      network = {
        bridge = "vmbr0"
        ip     = "192.0.2.10/24"
        gw     = "192.0.2.1"
        tag    = 20
      }
      tags = "ci;tftest"
    }
  }

  container_details = {
    target_node  = "zoidberg"
    ostemplate   = "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
    storage      = "local-lvm"
    nameserver   = "192.0.2.53 192.0.2.54"
    unprivileged = true
    start        = false
    onboot       = false
  }
}

run "vmid_output_maps_key_to_configured_vmid" {
  command = plan

  assert {
    condition     = output.vmids["tftest-unit-lxc"] == 5900
    error_message = "vmids output must map each container key to its configured vmid"
  }
}

run "ip_output_exposes_eth0_cidr_from_network_var" {
  command = plan

  assert {
    condition     = output.ip_addresses["tftest-unit-lxc"] == "192.0.2.10/24"
    error_message = "ip_addresses output must expose the eth0 CIDR taken from containers.network.ip"
  }
}

run "one_container_planned_per_input_entry" {
  command = plan

  # OpenTofu 1.12.5 has no mock introspection (mock_resources), so assert
  # the passthrough invariant instead: every container key yields a vmid.
  assert {
    condition     = length(keys(var.containers)) == length(keys(output.vmids))
    error_message = "exactly one container must be planned per input entry"
  }
}
