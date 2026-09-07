run "vm_creates_on_reserved_vmid" {
  command = apply

  assert {
    condition     = module.under_test.vmids["tftest-live-vm"] == 5901
    error_message = "live VM must be created on reserved vmid 5901"
  }
}
