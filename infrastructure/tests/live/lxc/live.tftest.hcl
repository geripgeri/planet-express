# Single apply-run: create the guest, prove it reached the reserved vmid,
# then the framework destroys everything automatically — including when an
# assertion fails.

run "lxc_boots_on_reserved_vmid" {
  command = apply

  assert {
    condition     = module.under_test.vmids["tftest-live-lxc"] == 5900
    error_message = "live LXC must come up on reserved vmid 5900"
  }

  assert {
    condition     = can(module.under_test.ip_addresses["tftest-live-lxc"])
    error_message = "ip_addresses output must carry an entry for the live guest"
  }
}
