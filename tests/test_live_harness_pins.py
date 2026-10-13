import pathlib
import re

HARNESS = pathlib.Path("infrastructure/tests/live/lxc/main.tf")
ANSIBLE_DEFAULTS = pathlib.Path("ansible/roles/proxmox_base/defaults/main.yaml")
ANSIBLE_KEY = "proxmox_base_pveam_template"
OSTEMPLATE_PIN = re.compile(r"debian-\d+-standard_\d+\.\d+-\d+_amd64\.tar\.zst")


def test_live_lxc_harness_carries_no_template_pin():
    """The harness must not hold a second copy of the Renovate-managed pin."""
    assert OSTEMPLATE_PIN.search(ANSIBLE_DEFAULTS.read_text()), (
        "the Ansible defaults no longer hold a template pin; this check is stale"
    )

    assert not OSTEMPLATE_PIN.search(HARNESS.read_text()), (
        f"{HARNESS} hardcodes a copy of {ANSIBLE_KEY}; Renovate updates only the "
        "Ansible line, so a copied pin drifts silently"
    )


def test_live_lxc_harness_reads_the_ansible_pin():
    """The harness must resolve ostemplate from the same key base.hcl uses."""
    text = HARNESS.read_text()

    assert "ansible/roles/proxmox_base/defaults/main.yaml" in text, (
        f"{HARNESS} must read the pin from the Ansible defaults"
    )
    assert ANSIBLE_KEY in text, f"{HARNESS} must read {ANSIBLE_KEY}"
