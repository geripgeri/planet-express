# var.proxmox is consumed by the terragrunt-generated provider.tf in the
# unit dir, which tflint cannot see.
rule "terraform_unused_declarations" {
  enabled = false
}
