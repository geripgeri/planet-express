# Unit tier for rolling upgrade: single null_resource, sorted workers, controller last.
mock_provider "talos" {}
mock_provider "null" {}

variables {
  talos_cluster_details   = { name = "talos-cluster-01", version = "v1.13.9", kubernetes_version = "1.35.8", longhorn_disk_size = "100GB" }
  machine_secrets_version = "v1.12.4"
  controller_ips          = ["192.0.2.10"]
  controller_vmid         = 500
  workers = {
    "talos-worker-01" = { ip = "192.0.2.11", vmid = 501 }
    "talos-worker-02" = { ip = "192.0.2.12", vmid = 502 }
    "talos-worker-03" = { ip = "192.0.2.13", vmid = 503 }
  }
  network_config = {
    vlan-10 = { subnet = "192.0.2.0/24", gateway = "192.0.2.1", nameservers = ["192.0.2.53"] }
    vlan-20 = { subnet = "198.51.100.0/24", gateway = "198.51.100.1", nameservers = ["198.51.100.53"] }
  }
}

run "rolling_upgrade_triggers_sorted_workers" {
  command = plan
  # rolling_upgrade should exist and have triggers with sorted IPs
  assert {
    condition     = contains(keys(null_resource.rolling_upgrade.triggers), "worker_ips")
    error_message = "rolling_upgrade must have worker_ips trigger"
  }
  assert {
    condition     = null_resource.rolling_upgrade.triggers.worker_ips == "192.0.2.11,192.0.2.12,192.0.2.13"
    error_message = "worker_ips must be sorted comma-separated"
  }
}

run "no_parallel_upgrade_resources" {
  command = plan
  # old parallel resources removed, rolling_upgrade must have controller_image trigger key (value unknown at plan)
  assert {
    condition     = contains(keys(null_resource.rolling_upgrade.triggers), "controller_image")
    error_message = "rolling_upgrade must have controller_image trigger"
  }
  assert {
    condition     = contains(keys(null_resource.rolling_upgrade.triggers), "worker_image")
    error_message = "rolling_upgrade must have worker_image trigger"
  }
}
