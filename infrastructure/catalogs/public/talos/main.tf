terraform {
  required_version = ">= 1.12.5"
  required_providers {
    local = {
      source  = "opentofu/local"
      version = "~> 2.5"
    }

    null = {
      source  = "opentofu/null"
      version = "3.3.1"
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

# Machine secrets are generated once, at bootstrap, and all nodes + every
# operator talosconfig trust the resulting CAs. They must never be
# regenerated: deriving talos_version from the current cluster version
# rotates every CA on each upgrade and locks out all clients with x509
# errors (see docs/runbooks/talos-k8s-upgrade.md §7). Pin to the
# bootstrap-time version via machine_secrets_version.
resource "talos_machine_secrets" "this" {
  talos_version = var.machine_secrets_version
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

# Bootstrap the cluster. First wait until the Talos API on every node
# answers (a fixed sleep does not survive slow boots, so poll with a bounded
# retry). The etcd status check doubles as an idempotency guard: on an
# already bootstrapped cluster (e.g. local state was lost but the cluster
# survived) the check succeeds and bootstrap is skipped, keeping a rebuild
# apply non-destructive.
resource "null_resource" "cluster_bootstrap" {
  triggers = {
    controller_ip = var.controller_ips[0]
    config_hash   = data.talos_client_configuration.this.talos_config
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      MAX_ATTEMPTS=90
      SLEEP_INTERVAL=10

      # Only wait for controller to be up before bootstrap; workers are
      # waited for via cluster_health after bootstrap. Waiting for all
      # nodes before bootstrap adds 3*15m and blocks bootstrap.
      for node in ${join(" ", var.controller_ips)}; do
        echo "Waiting for Talos API on $node..."
        UP=0
        LAST_ERR=""
        for i in $(seq 1 $MAX_ATTEMPTS); do
          # Capture output so failures are diagnosable; Talos API may be
          # down during install/reboot, or TLS may mismatch. Do not hide
          # errors on the final attempt.
          if OUT=$(talosctl --talosconfig="${local.talos_config_path}" \
            -n "$node" version 2>&1); then
            echo "Node $node is up (attempt $i/$MAX_ATTEMPTS)"
            UP=1
            break
          else
            LAST_ERR="$OUT"
            # Log every 6th attempt to avoid spam but keep visibility
            if [ $((i % 6)) -eq 0 ]; then
              echo "  attempt $i/$MAX_ATTEMPTS: $OUT" | head -n 5
            fi
          fi
          sleep $SLEEP_INTERVAL
        done

        if [ "$UP" != "1" ]; then
          echo "ERROR: Node $node did not become reachable within $((MAX_ATTEMPTS * SLEEP_INTERVAL))s" >&2
          echo "Last talosctl version error:" >&2
          printf '%s\n' "$LAST_ERR" >&2
          echo "Check: talosconfig at ${local.talos_config_path} (endpoints/nodes), network reachability to $node:50000, and VM console via Proxmox (qm terminal $node vmid)." >&2
          exit 1
        fi
      done

      # Compare talosctl client vs server version; mismatch (1.13.8 vs 1.13.9) caused hang.
      CLIENT_TAG=$(talosctl version --client 2>&1 | awk '/Tag:/{print $2; exit}')
      SERVER_TAG=$(talosctl --talosconfig="${local.talos_config_path}" -n ${var.controller_ips[0]} version 2>&1 | awk '/^Server:/{s=1} s && /Tag:/{print $2; exit}')
      if [ -n "$CLIENT_TAG" ] && [ -n "$SERVER_TAG" ] && [ "$CLIENT_TAG" != "$SERVER_TAG" ]; then
        echo "ERROR: talosctl client $CLIENT_TAG != server $SERVER_TAG for ${var.controller_ips[0]}, update talosctl to $SERVER_TAG" >&2
        exit 1
      fi

      # etcd status hangs forever in maintenance mode before bootstrap, use timeout.
      # talosctl version works even in maintenance mode (shows all nodes), so etcd hang + version success = not bootstrapped.
      if timeout 10 talosctl --talosconfig="${local.talos_config_path}" -n ${var.controller_ips[0]} etcd status >/dev/null 2>&1; then
        echo "Cluster is already bootstrapped, skipping bootstrap"
        exit 0
      fi

      echo "Bootstrapping the cluster via ${var.controller_ips[0]}..."
      talosctl --talosconfig="${local.talos_config_path}" -n ${var.controller_ips[0]} bootstrap
    EOT
  }

  depends_on = [
    null_resource.talos_config,
    talos_machine_configuration_apply.controller,
    talos_machine_configuration_apply.worker,
  ]
}

# Collect the kubeconfig of the Talos cluster created
resource "talos_cluster_kubeconfig" "this" {
  depends_on = [
    null_resource.cluster_bootstrap,
    null_resource.cluster_health,
  ]
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = var.controller_ips[0]
}

# Write talos config to a stable path outside .terragrunt-stack and keep the
# default ~/.talos/config pointing at it
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
      ln -sf ${local.talos_config_path} ~/.talos/config
      echo "Talos config symlinked to ~/.talos/config"
    EOT
  }
}

# Write kubeconfig to a stable path outside .terragrunt-stack and keep the
# default ~/.kube/config pointing at it
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
      ln -sf ${local.kubeconfig_path} ~/.kube/config
      echo "Kubeconfig symlinked to ~/.kube/config"
    EOT
  }

  depends_on = [talos_cluster_kubeconfig.this]
}

# Rolling upgrade: workers sorted by IP one-by-one then controller last.
# Replaces parallel upgrade_controller + upgrade_worker for_each which rebooted all nodes at once.
resource "null_resource" "rolling_upgrade" {
  triggers = {
    controller_image = data.talos_image_factory_urls.controller.urls.installer
    worker_image     = data.talos_image_factory_urls.worker.urls.installer
    worker_ips       = join(",", sort([for k, v in var.workers : v.ip]))
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<EOT
      set -e
      TARGET_VERSION="${var.talos_cluster_details.version}"
      echo "Rolling upgrade workers (target $TARGET_VERSION)..."
      IFS=',' read -ra IPS <<< "${self.triggers.worker_ips}"
      for ip in "$${IPS[@]}"; do
        if [ -z "$ip" ]; then continue; fi
        echo "Waiting for $ip to be reachable before upgrade..."
        for i in $(seq 1 18); do
          if talosctl --talosconfig="${local.talos_config_path}" -n "$ip" version >/dev/null 2>&1; then
            break
          fi
          echo "  $ip not ready, attempt $i/18, waiting 10s..."
          sleep 10
        done
        CURRENT_TAG=$(talosctl --talosconfig="${local.talos_config_path}" -n "$ip" version 2>&1 | awk '/^Server:/{s=1} s && /Tag:/{print $2; exit}')
        if [ "$CURRENT_TAG" = "$TARGET_VERSION" ]; then
          echo "Worker $ip already on $TARGET_VERSION, skipping upgrade"
          continue
        fi
        echo "Upgrading worker $ip from $CURRENT_TAG to $TARGET_VERSION with ${self.triggers.worker_image}..."
        talosctl --talosconfig="${local.talos_config_path}" -n "$ip" upgrade --image ${self.triggers.worker_image} || echo "Upgrade command for $ip returned non-zero, continuing (may already be upgrading)"
        echo "Waiting for $ip to reboot after upgrade..."
        sleep 20
        for i in $(seq 1 18); do
          if talosctl --talosconfig="${local.talos_config_path}" -n "$ip" version >/dev/null 2>&1; then
            echo "Worker $ip back up after upgrade"
            break
          fi
          sleep 10
        done
      done
      echo "Waiting for controller ${var.controller_ips[0]} to be reachable..."
      for i in $(seq 1 18); do
        if talosctl --talosconfig="${local.talos_config_path}" -n ${var.controller_ips[0]} version >/dev/null 2>&1; then
          break
        fi
        sleep 10
      done
      CONTROLLER_TAG=$(talosctl --talosconfig="${local.talos_config_path}" -n ${var.controller_ips[0]} version 2>&1 | awk '/^Server:/{s=1} s && /Tag:/{print $2; exit}')
      if [ "$CONTROLLER_TAG" = "$TARGET_VERSION" ]; then
        echo "Controller already on $TARGET_VERSION, skipping upgrade"
        exit 0
      fi
      echo "Upgrading controller ${var.controller_ips[0]} from $CONTROLLER_TAG to $TARGET_VERSION..."
      talosctl --talosconfig="${local.talos_config_path}" -n ${var.controller_ips[0]} upgrade --image ${self.triggers.controller_image}
    EOT
  }

  depends_on = [
    null_resource.talos_config,
    talos_machine_configuration_apply.controller,
    talos_machine_configuration_apply.worker,
    null_resource.cluster_health,
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

      echo "Checking all nodes are reachable (with retry for booting workers)..."
      MAX_ATTEMPTS=18
      SLEEP_INTERVAL=10
      NODES="${join(" ", concat(var.controller_ips, [for w in var.workers : w.ip]))}"
      for node in $NODES; do
        UP=0
        for i in $(seq 1 $MAX_ATTEMPTS); do
          if talosctl --talosconfig="${local.talos_config_path}" -n "$node" get machinestatus >/dev/null 2>&1; then
            echo "Node $node reachable"
            UP=1
            break
          fi
          echo "Waiting for $node machinestatus (attempt $i/$MAX_ATTEMPTS)..."
          sleep $SLEEP_INTERVAL
        done
        if [ "$UP" != "1" ]; then
          echo "ERROR: Node $node not reachable after $((MAX_ATTEMPTS * SLEEP_INTERVAL))s" >&2
          exit 1
        fi
      done

      echo "Talos cluster is healthy"
    EOT
  }

  depends_on = [
    null_resource.talos_config,
    null_resource.cluster_bootstrap,
  ]
}

# Final convergence check: fail the apply if any node did not reach the
# expected Talos or Kubernetes version. Upgrades block until each node
# reports back, but a reboot race or partial install/rollout could still
# leave a node stale; this fails the apply instead of hiding it (see
# docs/runbooks/talos-k8s-upgrade.md §5b).
resource "null_resource" "verify_upgrade" {
  triggers = {
    talos_version      = var.talos_cluster_details.version
    kubernetes_version = var.talos_cluster_details.kubernetes_version
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      NODES="${join(" ", concat(var.controller_ips, [for w in var.workers : w.ip]))}"
      MAX_ATTEMPTS=90
      SLEEP_INTERVAL=10

      for node in $NODES; do
        echo "Verifying Talos version on $node..."
        OK=0
        LAST_OUT=
        for i in $(seq 1 $MAX_ATTEMPTS); do
          # Text output is stable across talosctl versions; the JSON form is
          # protojson of the API message (no `server.tag` key) and `-o json`
          # is not a registered flag at all. Keep stderr on failure so a
          # broken probe fails loudly instead of silently (upgrade incident).
          OUT=$(talosctl --talosconfig="${local.talos_config_path}" \
            -n "$node" version 2>&1)
          LAST_OUT="$OUT"
          TAG=$(printf '%s\n' "$OUT" \
            | awk '/^Server:/{s=1} s && /^[[:space:]]*Tag:/{print $2; exit}')
          if [ "$TAG" = "${var.talos_cluster_details.version}" ]; then
            OK=1
            break
          fi
          sleep $SLEEP_INTERVAL
        done

        if [ "$OK" != "1" ]; then
          echo "ERROR: node $node did not reach Talos ${var.talos_cluster_details.version} in time (probe returned '$TAG'); last talosctl output:" >&2
          printf '%s\n' "$LAST_OUT" >&2
          exit 1
        fi
        echo "node $node: Talos $TAG OK"
      done

      EXPECTED_KUBELET="v${var.talos_cluster_details.kubernetes_version}"
      echo "Waiting for all nodes to report kubelet $EXPECTED_KUBELET (Ready check skipped for CNI none)..."
      for i in $(seq 1 $MAX_ATTEMPTS); do
        OUT=$(kubectl --kubeconfig="${local.kubeconfig_path}" get nodes --no-headers 2>/dev/null)
        if [ -z "$OUT" ]; then
          sleep $SLEEP_INTERVAL
          continue
        fi
        # Only check kubelet version, not Ready – CNI (cilium) is not installed via Talos (cni: none),
        # so nodes stay NotReady until ArgoCD deploys Cilium. Ready is checked separately if needed.
        BAD=$(printf '%s\n' "$OUT" | awk -v want="$EXPECTED_KUBELET" \
          '$(NF) != want { print $1 " kubelet=" $(NF) " want=" want }')
        [ -z "$BAD" ] && break
        # Log status for visibility but don't fail on NotReady alone
        echo "  waiting kubelet $EXPECTED_KUBELET, current: $BAD (attempt $i/$MAX_ATTEMPTS)" | head -n 5
        sleep $SLEEP_INTERVAL
      done

      if [ -n "$BAD" ]; then
        echo "ERROR: nodes did not converge on kubelet $EXPECTED_KUBELET within $((MAX_ATTEMPTS * SLEEP_INTERVAL))s:" >&2
        printf '%s\n' "$BAD" >&2
        kubectl --kubeconfig="${local.kubeconfig_path}" get nodes >&2
        exit 1
      fi
      echo "All nodes on kubelet $EXPECTED_KUBELET (Ready may still be NotReady until CNI installs)"
      kubectl --kubeconfig="${local.kubeconfig_path}" get nodes 2>&1 | head -n 20
    EOT
  }

  depends_on = [
    null_resource.rolling_upgrade,
    null_resource.kubeconfig,
  ]
}
