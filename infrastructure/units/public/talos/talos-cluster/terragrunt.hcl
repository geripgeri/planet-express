include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}//infrastructure/catalogs/public/talos"
}

dependency "talos_vms" {
  config_path = "../talos-vms"
}

inputs = {
  talos_cluster_details = {
    name               = "talos-cluster-01"
    version            = "v1.12.4"
    longhorn_disk_size = "100GB"
  }

  controller_ips  = [dependency.talos_vms.outputs.ip_addresses["talos-controller-01"]]
  controller_vmid = dependency.talos_vms.outputs.vmids["talos-controller-01"]

  workers = {
    talos-worker-01 = {
      ip   = dependency.talos_vms.outputs.ip_addresses["talos-worker-01"]
      vmid = dependency.talos_vms.outputs.vmids["talos-worker-01"]
    }

    talos-worker-02 = {
      ip   = dependency.talos_vms.outputs.ip_addresses["talos-worker-02"]
      vmid = dependency.talos_vms.outputs.vmids["talos-worker-02"]
    }

    talos-worker-03 = {
      ip   = dependency.talos_vms.outputs.ip_addresses["talos-worker-03"]
      vmid = dependency.talos_vms.outputs.vmids["talos-worker-03"]
    }
  }
}
