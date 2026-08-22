locals {
  repo_root = get_repo_root()
}

# The tofu-state unit is applied only after the garage-lxc unit (proxmox
# stack) provisioned the container AND the garage Ansible role bootstrapped
# the guest (docs/runbooks/garage-lxc-setup.md). The guest setup is not
# enforceable in the stack DAG: the unit fails cleanly while the admin API
# is unreachable, which is the actual guard.
unit "tofu_state" {
  source = "${local.repo_root}/infrastructure/units/public/garage/tofu-state"
  path   = "tofu-state"
}
