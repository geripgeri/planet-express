terraform {
  required_version = ">= 1.12.5"
  required_providers {
    local = {
      source  = "opentofu/local"
      version = "~> 2.5"
    }

    null = {
      source  = "opentofu/null"
      version = "3.3.0"
    }

    talos = {
      source  = "siderolabs/talos"
      version = "0.11.0"
    }
  }
}

locals {
  platform = "metal"

  talos_config_path = pathexpand("~/.talos/${var.talos_cluster_details.name}.yaml")
  kubeconfig_path   = pathexpand("~/.kube/${var.talos_cluster_details.name}.yaml")
}

# Generate machine secrets for Talos cluster
resource "talos_machine_secrets" "this" {
  talos_version = var.talos_cluster_details.version
}

# Minimal schematic for controllers (no extra extensions)
resource "talos_image_factory_schematic" "controller" {
  schematic = yamlencode({
    customization = {
      systemExtensions = {
        officialExtensions = [
          "siderolabs/qemu-guest-agent"
        ]
      }
    }
  })
}

# Worker schematic with Longhorn dependencies
resource "talos_image_factory_schematic" "worker" {
  schematic = yamlencode({
    customization = {
      systemExtensions = {
        officialExtensions = [
          "siderolabs/qemu-guest-agent",
          "siderolabs/iscsi-tools",
          "siderolabs/util-linux-tools",
        ]
      }
    }
  })
}

# Apply the machine configuration created in the data section for the controller node
resource "talos_machine_configuration_apply" "controller" {
  client_configuration        = data.talos_client_configuration.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.controller.machine_configuration
  node                        = var.controller_ips[0]
}

# Apply the machine configuration created in the data section for the worker node
resource "talos_machine_configuration_apply" "worker" {
  for_each = var.workers

  client_configuration        = data.talos_client_configuration.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker[each.key].machine_configuration
  node                        = each.value.ip
}

# Start the bootstrapping of the cluster
resource "talos_machine_bootstrap" "this" {
  depends_on           = [talos_machine_configuration_apply.controller]
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = var.controller_ips[0]
}

# Collect the kubeconfig of the Talos cluster created
resource "talos_cluster_kubeconfig" "this" {
  depends_on = [
    talos_machine_bootstrap.this,
    null_resource.cluster_health,
  ]
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = var.controller_ips[0]
}

# Write talos config to a stable path outside .terragrunt-stack
resource "null_resource" "talos_config" {
  triggers = {
    content = sha256(data.talos_client_configuration.this.talos_config)
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      mkdir -p ~/.talos
      cat > ${local.talos_config_path} << 'YAML'
      ${data.talos_client_configuration.this.talos_config}
      YAML
      chmod 0600 ${local.talos_config_path}
    EOT
  }
}

# Write kubeconfig to a stable path outside .terragrunt-stack
resource "null_resource" "kubeconfig" {
  triggers = {
    content = sha256(talos_cluster_kubeconfig.this.kubeconfig_raw)
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      mkdir -p ~/.kube
      cat > ${local.kubeconfig_path} << 'YAML'
      ${talos_cluster_kubeconfig.this.kubeconfig_raw}
      YAML
      chmod 0600 ${local.kubeconfig_path}
    EOT
  }

  depends_on = [talos_cluster_kubeconfig.this]
}

# Set a sleep condition and afterwards check the Health status of the Talos cluster
resource "null_resource" "wait_for_agent" {
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<EOT
      echo "Waiting for QEMU Guest Agent to be operational..."
      sleep 90
    EOT
  }

  depends_on = [
    talos_machine_configuration_apply.controller,
    talos_machine_configuration_apply.worker,
  ]
}

# Apply changes if needed
resource "null_resource" "upgrade_controller" {
  triggers = {
    installer_image = data.talos_image_factory_urls.controller.urls.installer
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<EOT
      echo "Starting Talos controller upgrade for: ${var.controller_ips[0]}..."
      talosctl upgrade \
        --talosconfig="${local.talos_config_path}" \
        -n ${var.controller_ips[0]} \
        --image ${data.talos_image_factory_urls.controller.urls.installer} \
        --wait=false
    EOT
  }

  depends_on = [
    null_resource.talos_config,
    talos_machine_configuration_apply.controller,
    null_resource.cluster_health,
  ]
}

resource "null_resource" "upgrade_worker" {
  for_each = var.workers

  triggers = {
    installer_image = data.talos_image_factory_urls.worker.urls.installer
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<EOT
      echo "Starting Talos worker upgrade for: ${each.value.ip}..."
      talosctl upgrade \
        --talosconfig="${local.talos_config_path}" \
        -n ${each.value.ip} \
        --image ${data.talos_image_factory_urls.worker.urls.installer} \
        --wait=false
    EOT
  }

  depends_on = [
    null_resource.talos_config,
    talos_machine_configuration_apply.worker,
    null_resource.cluster_health,
  ]
}

# Automatically create and/or update kube and talos configs
resource "null_resource" "update_configs" {
  triggers = {
    kubeconfig    = sha256(talos_cluster_kubeconfig.this.kubeconfig_raw)
    client_config = sha256(data.talos_client_configuration.this.talos_config)
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<EOT
      ln -sf ${local.kubeconfig_path} ~/.kube/config
      echo "Kubeconfig symlinked to ~/.kube/config"
    EOT
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<EOT
      ln -sf ${local.talos_config_path} ~/.talos/config
      echo "Talos config symlinked to ~/.talos/config"
    EOT
  }

  depends_on = [
    null_resource.kubeconfig,
    null_resource.talos_config,
    talos_cluster_kubeconfig.this,
  ]
}

# Check whether the Talos cluster is in a healthy state
resource "null_resource" "cluster_health" {
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      echo "Checking etcd health..."
      talosctl --talosconfig="${local.talos_config_path}" \
        -n ${var.controller_ips[0]} \
        etcd status

      echo "Checking all nodes are reachable..."
      talosctl --talosconfig="${local.talos_config_path}" \
        -n ${join(",", concat(var.controller_ips, [for w in var.workers : w.ip]))} \
        get machinestatus

      echo "Talos cluster is healthy"
    EOT
  }

  depends_on = [
    null_resource.talos_config,
    talos_machine_bootstrap.this,
    null_resource.wait_for_agent,
  ]
}

resource "null_resource" "wait_for_nodes_ready" {
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      EXPECTED_NODES=${length(var.controller_ips) + length(var.workers)}
      MAX_ATTEMPTS=60
      SLEEP_INTERVAL=10

      echo "Waiting for $EXPECTED_NODES node(s) to appear..."

      for i in $(seq 1 $MAX_ATTEMPTS); do
        CURRENT_NODES=$(kubectl get nodes \
          --no-headers 2>/dev/null \
          | wc -l | tr -d ' ')

        echo "Attempt $i/$MAX_ATTEMPTS: $CURRENT_NODES/$EXPECTED_NODES nodes registered"

        if [ "$CURRENT_NODES" -ge "$EXPECTED_NODES" ]; then
          echo "All $EXPECTED_NODES node(s) are registered!"
          kubectl get nodes
          exit 0
        fi

        sleep $SLEEP_INTERVAL
      done

      echo "ERROR: Timed out after $((MAX_ATTEMPTS * SLEEP_INTERVAL))s waiting for nodes to appear"
      kubectl get nodes
      exit 1
    EOT
  }

  depends_on = [
    null_resource.update_configs,
    null_resource.cluster_health,
  ]
}
