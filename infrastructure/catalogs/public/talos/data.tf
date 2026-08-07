data "talos_image_factory_urls" "controller" {
  talos_version = var.talos_cluster_details.version
  schematic_id  = talos_image_factory_schematic.controller.id
  platform      = local.platform
}

data "talos_image_factory_urls" "worker" {
  talos_version = var.talos_cluster_details.version
  schematic_id  = talos_image_factory_schematic.worker.id
  platform      = local.platform
}

# Generate the Talos client configuration
data "talos_client_configuration" "this" {
  cluster_name         = var.talos_cluster_details.name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = var.controller_ips
  nodes                = concat(var.controller_ips, [for w in var.workers : w.ip])
}

# Generate the controller configuration and instantiate the Initial Image for the Talos configuration
data "talos_machine_configuration" "controller" {
  cluster_name     = var.talos_cluster_details.name
  talos_version    = var.talos_cluster_details.version
  cluster_endpoint = "https://${var.controller_ips[0]}:6443"
  machine_type     = "controlplane"
  machine_secrets  = talos_machine_secrets.this.machine_secrets
  config_patches = [
    templatefile("${path.module}/files/init_install_controller.tfmpl", {
      initial_image = data.talos_image_factory_urls.controller.urls.installer
    }),
    templatefile("${path.module}/files/vlan20_interface.tfmpl", {
      vlan10_nameservers = var.network_config.vlan-10.nameservers
      vlan10_gateway     = var.network_config.vlan-10.gateway
      vlan20_ip          = "${cidrhost(var.network_config.vlan-20.subnet, var.controller_vmid - 400)}/${split("/", var.network_config.vlan-20.subnet)[1]}"
    }),
  ]
}

# Generate the worker configuration and instantiate the Initial Image for the Talos configuration
data "talos_machine_configuration" "worker" {
  for_each = var.workers

  cluster_name     = var.talos_cluster_details.name
  talos_version    = var.talos_cluster_details.version
  cluster_endpoint = "https://${var.controller_ips[0]}:6443"
  machine_type     = "worker"
  machine_secrets  = talos_machine_secrets.this.machine_secrets
  config_patches = [
    templatefile("${path.module}/files/init_install_worker.tfmpl", {
      initial_image = data.talos_image_factory_urls.worker.urls.installer
    }),
    templatefile("${path.module}/files/longhorn_volume.tfmpl", {
      longhorn_disk_size = var.talos_cluster_details.longhorn_disk_size
    }),
    templatefile("${path.module}/files/vlan20_interface.tfmpl", {
      vlan10_nameservers = var.network_config.vlan-10.nameservers
      vlan10_gateway     = var.network_config.vlan-10.gateway
      vlan20_ip          = "${cidrhost(var.network_config.vlan-20.subnet, each.value.vmid - 400)}/${split("/", var.network_config.vlan-20.subnet)[1]}"
    }),
  ]
}
