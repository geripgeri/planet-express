"""Guard: live harnesses carry no provider version pins.

Catalogs hold the versions (Renovate's only pin target). A duplicated
pin once drifted (harness random 3.9.0 vs catalog 3.9.1), and merged
exact constraints made tofu init unsolvable.
"""

import re
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
HARNESSES = [
    "infrastructure/tests/live/lxc/main.tf",
    "infrastructure/tests/live/vm/main.tf",
]
CATALOGS = [
    "infrastructure/catalogs/public/lxc/main.tf",
    "infrastructure/catalogs/public/proxmox-vm/main.tf",
]


def required_providers_body(path):
    text = Path(path).read_text(encoding="utf-8")
    match = re.search(r"required_providers\s*\{(?P<block>.*?)\n  \}", text, re.DOTALL)
    return match.group("block") if match else ""


@pytest.mark.parametrize("path", HARNESSES)
def test_harness_carries_no_provider_version_pins(path):
    """The harness root must declare sources only, never versions."""
    body = required_providers_body(REPO / path)
    assert body, f"required_providers not found in {path}"
    assert not re.search(r"\bversion\s*=", body), (
        f"{path}: duplicate provider pin; catalogs are the pin source"
    )


@pytest.mark.parametrize("path", CATALOGS)
def test_catalog_pin_files_exist(path):
    """The pin source must remain present and non-empty."""
    assert (REPO / path).is_file(), f"catalog file missing: {path}"
    body = required_providers_body(REPO / path)
    assert body and re.search(r"\bversion\s*=", body), (
        f"{path}: no tracked provider pin; Renovate loses its target"
    )
