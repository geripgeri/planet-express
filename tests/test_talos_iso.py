import pathlib
import re

import yaml


def test_talos_iso_version_single_source():
    defaults = yaml.safe_load(
        pathlib.Path("ansible/roles/proxmox_base/defaults/main.yaml").read_text()
    )
    assert "proxmox_base_talos_iso_version" in defaults, (
        "proxmox_base_talos_iso_version missing in proxmox_base defaults"
    )
    assert re.match(r"^v\d+\.\d+\.\d+$", defaults["proxmox_base_talos_iso_version"])
    # terragrunt must read same file
    tg = pathlib.Path(
        "infrastructure/units/public/proxmox/talos-vms/terragrunt.hcl"
    ).read_text()
    assert "proxmox_base_talos_iso_version" in tg
    assert "talos-${local.talos_iso_version}-nocloud" in tg or "talos_iso_version" in tg


def test_renovate_manages_talos_iso():
    text = pathlib.Path("renovate.json5").read_text()
    assert "proxmox_base_talos_iso_version" in text, (
        "Renovate customManager for proxmox_base_talos_iso_version missing"
    )
    assert "siderolabs/talos" in text
