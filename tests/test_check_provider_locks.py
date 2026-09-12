import pytest

from scripts.check_provider_locks import (
    compare_versions,
    parse_version,
    satisfies_constraint,
)


@pytest.mark.parametrize(
    ("version", "expected"),
    [
        ("3.0.2", (3, 0, 2, None)),
        ("3.0.2-rc10", (3, 0, 2, "rc10")),
        ("3.0.2-rc09", (3, 0, 2, "rc09")),
        ("garbage", None),
        ("3.0", None),
    ],
)
def test_parse_version(version, expected):
    assert parse_version(version) == expected


@pytest.mark.parametrize(
    ("a", "b", "expected"),
    [
        ("3.0.2", "3.0.2", 0),
        ("3.0.1", "3.0.2", -1),
        ("3.1.0", "3.0.2", 1),
        ("3.0.2-rc09", "3.0.2-rc10", -1),
        ("3.0.2-rc10", "3.0.2-rc09", 1),
        ("3.0.2-rc10", "3.0.2", -1),
        ("3.0.2", "3.0.2-rc10", 1),
        ("nope", "3.0.2", None),
        ("3.0.2-rc9", "3.0.2-rc9.1", -1),
        ("3.0.2-rc9.1", "3.0.2-rc9", 1),
    ],
)
def test_compare_versions(a, b, expected):
    assert compare_versions(a, b) == expected


@pytest.mark.parametrize(
    ("locked", "constraint", "expected"),
    [
        ("3.0.2-rc10", "3.0.2-rc10", True),
        ("3.0.2-rc10", "= 3.0.2-rc10", True),
        ("3.0.2-rc07", "3.0.2-rc10", False),
        ("3.0.2", "3.0.2", True),
        ("3.0.3", "~> 3.0.2", True),
        ("3.1.0", "~> 3.0.2", False),
        ("3.0.0", "~> 3.0.2", False),
        ("4.0.0", "~> 3.0", False),
        ("3.9.0", "~> 3.0", True),
        ("2.9.9", "~> 2.5", True),
        ("2.4.9", "~> 2.5", False),
        ("3.0.0", "~> 2.5", False),
        ("1.9.9", "~> 1", True),
        ("2.0.0", "~> 1", False),
        ("garbage", ">= 1.0", None),
        ("garbage", "!= anything", True),
        ("3.0.2", "garbage != anything", None),
        ("3.0.2", ">= 3.0", True),
        ("2.9.9", ">= 3.0", False),
        ("3.1.1", "3.1.1, != 3.1.0", True),
        ("3.1.1", "3.1.1, != 3.1.1", False),
        ("3.1.9", ">= 3.1.1, < 3.2", True),
        ("3.3.0", ">= 3.1.1, < 3.2", False),
        ("3.3.0", "3.1.1, < 3.2", False),
        ("garbage", "3.1.1", None),
        ("3.1.1", "whatever-one", None),
    ],
)
def test_satisfies_constraint(locked, constraint, expected):
    assert satisfies_constraint(locked, constraint) is expected


import subprocess
import sys
import textwrap
from pathlib import Path

import scripts.check_provider_locks as cpl
from scripts.check_provider_locks import (
    check_unit,
    find_units,
    parse_lock_file,
    parse_required_providers,
    resolve_catalog_dir,
)

CATALOG_MAIN_TF = textwrap.dedent(
    """\
    terraform {
      required_providers {
        proxmox = {
          source  = "telmate/proxmox"
          version = "3.0.2-rc10"
        }
        random = {
          source  = "opentofu/random"
        }
      }
    }
    """
)

LOCK_RC07 = textwrap.dedent(
    """\
    provider "registry.opentofu.org/telmate/proxmox" {
      version     = "3.0.2-rc07"
      constraints = "3.0.2-rc07"
      hashes = [
        "h1:abc",
      ]
    }
    """
)

LOCK_RC10 = LOCK_RC07.replace("3.0.2-rc07", "3.0.2-rc10")

LOCK_RANDOM_ONLY = textwrap.dedent(
    """\
    provider "registry.opentofu.org/opentofu/random" {
      version     = "3.9.0"
      constraints = "3.9.0"
      hashes = [
        "h1:def",
      ]
    }
    """
)


def _catalog(tmp_path, name="proxmox-vm", tf=CATALOG_MAIN_TF):
    cat = tmp_path / "infrastructure" / "catalogs" / "public" / name
    cat.mkdir(parents=True)
    (cat / "main.tf").write_text(tf, encoding="utf-8")
    return cat


def _unit(tmp_path, lock=None, source=None):
    unit = tmp_path / "infrastructure" / "units" / "public" / "proxmox" / "talos-vms"
    unit.mkdir(parents=True)
    src = source or "${get_repo_root()}//infrastructure/catalogs/public/proxmox-vm"
    (unit / "terragrunt.hcl").write_text(
        f'terraform {{\n  source = "{src}"\n}}\n', encoding="utf-8"
    )
    if lock is not None:
        (unit / ".terraform.lock.hcl").write_text(lock, encoding="utf-8")
    return unit


def test_parse_required_providers_versions(tmp_path):
    providers = parse_required_providers(_catalog(tmp_path))
    assert providers["telmate/proxmox"] == "3.0.2-rc10"
    assert providers["opentofu/random"] is None


def test_parse_lock_file_versions(tmp_path):
    lock = tmp_path / "x.hcl"
    lock.write_text(LOCK_RC07, encoding="utf-8")
    assert parse_lock_file(lock) == {"telmate/proxmox": "3.0.2-rc07"}


def test_resolve_catalog_dir_get_repo_root(tmp_path):
    cat = _catalog(tmp_path)
    unit = _unit(tmp_path)
    src = "${get_repo_root()}//infrastructure/catalogs/public/proxmox-vm"
    assert resolve_catalog_dir(unit, src, tmp_path) == cat


def test_resolve_catalog_dir_unresolvable(tmp_path):
    unit = _unit(tmp_path)
    src = "${get_original_terragrunt_dir()}/foo"
    assert resolve_catalog_dir(unit, src, tmp_path) is None


def test_resolve_catalog_dir_relative(tmp_path):
    cat = _catalog(tmp_path)
    unit = _unit(tmp_path)
    src = "../../../../catalogs/public/proxmox-vm"
    assert resolve_catalog_dir(unit, src, tmp_path) == cat.resolve()


def test_find_units_skips_terragrunt_stack(tmp_path):
    _catalog(tmp_path)
    unit = _unit(tmp_path)
    st = unit / ".terragrunt-stack" / "proxmox" / "talos-vms"
    st.mkdir(parents=True)
    (st / "terragrunt.hcl").write_text(
        'terraform {\n  source = "nope"\n}\n', encoding="utf-8"
    )
    found = find_units(tmp_path / "infrastructure" / "units")
    assert found == [unit]


def test_find_units_ignores_units_without_source(tmp_path):
    _catalog(tmp_path)
    _unit(tmp_path)
    other = tmp_path / "infrastructure" / "units" / "public" / "argocd"
    other.mkdir(parents=True)
    (other / "terragrunt.hcl").write_text("locals {\n  x = 1\n}\n", encoding="utf-8")
    found = find_units(tmp_path / "infrastructure" / "units")
    assert len(found) == 1


def test_check_unit_clean(tmp_path):
    _catalog(tmp_path)
    unit = _unit(tmp_path, lock=LOCK_RC10)
    result = check_unit(unit, tmp_path)
    assert result.drift == []
    assert result.warnings == []


def test_check_unit_stale_lock_is_drift(tmp_path):
    _catalog(tmp_path)
    unit = _unit(tmp_path, lock=LOCK_RC07)
    result = check_unit(unit, tmp_path)
    assert any(
        "telmate/proxmox" in line and "3.0.2-rc07" in line for line in result.drift
    )


def test_check_unit_missing_lock_is_drift(tmp_path):
    _catalog(tmp_path)
    unit = _unit(tmp_path, lock=None)
    result = check_unit(unit, tmp_path)
    assert any("missing lock file" in line for line in result.drift)


def test_check_unit_provider_absent_from_lock_is_drift(tmp_path):
    _catalog(tmp_path)
    unit = _unit(tmp_path, lock=LOCK_RANDOM_ONLY)
    result = check_unit(unit, tmp_path)
    assert any(
        "telmate/proxmox" in line and "missing from lock" in line
        for line in result.drift
    )


def test_check_unit_unresolvable_source_is_warning(tmp_path):
    _catalog(tmp_path)
    unit = _unit(tmp_path, lock=LOCK_RC10, source="${get_original_terragrunt_dir()}/x")
    result = check_unit(unit, tmp_path)
    assert result.drift == []
    assert any("cannot resolve source" in line for line in result.warnings)


def _drift_tree(tmp_path):
    cat = tmp_path / "infrastructure" / "catalogs" / "public" / "proxmox-vm"
    cat.mkdir(parents=True)
    (cat / "main.tf").write_text(CATALOG_MAIN_TF, encoding="utf-8")
    unit = tmp_path / "infrastructure" / "units" / "public" / "proxmox" / "talos-vms"
    unit.mkdir(parents=True)
    (unit / "terragrunt.hcl").write_text(
        'terraform {\n  source = "${get_repo_root()}//infrastructure/catalogs/public/proxmox-vm"\n}\n',
        encoding="utf-8",
    )
    (unit / ".terraform.lock.hcl").write_text(LOCK_RC07, encoding="utf-8")
    return tmp_path


def test_check_mode_reports_drift_and_exits_1(tmp_path, capsys):
    tree = _drift_tree(tmp_path)
    assert cpl.main(["--check"], repo_root=tree) == 1
    out = capsys.readouterr().out
    assert "DRIFT" in out and "talos-vms" in out
    assert "terragrunt init -upgrade" in out


def test_fix_mode_resolves_drift(tmp_path, monkeypatch, capsys):
    tree = _drift_tree(tmp_path)
    calls: list[Path] = []

    def fake_fix(unit):
        calls.append(unit)
        (unit / ".terraform.lock.hcl").write_text(LOCK_RC10, encoding="utf-8")
        return True

    monkeypatch.setattr(cpl, "run_terragrunt_init", fake_fix)
    assert cpl.main(["--fix"], repo_root=tree) == 0
    assert len(calls) == 1
    assert calls[0].name == "talos-vms"
    assert (
        calls[0]
        == tree / "infrastructure" / "units" / "public" / "proxmox" / "talos-vms"
    )


def test_fix_mode_bad_lock_after_fix_exits_1(tmp_path, monkeypatch, capsys):
    tree = _drift_tree(tmp_path)

    def fake_fix(unit):
        return True

    monkeypatch.setattr(cpl, "run_terragrunt_init", fake_fix)
    assert cpl.main(["--fix"], repo_root=tree) == 1
    out = capsys.readouterr().out
    assert "after fix" in out


def test_fix_mode_terragrunt_failure_exits_1(tmp_path, monkeypatch):
    tree = _drift_tree(tmp_path)
    monkeypatch.setattr(cpl, "run_terragrunt_init", lambda unit: False)
    assert cpl.main(["--fix"], repo_root=tree) == 1


def test_clean_tree_exits_0(tmp_path):
    tree = _drift_tree(tmp_path)
    lock = (
        tree
        / "infrastructure"
        / "units"
        / "public"
        / "proxmox"
        / "talos-vms"
        / ".terraform.lock.hcl"
    )
    lock.write_text(LOCK_RC10, encoding="utf-8")
    assert cpl.main(["--check"], repo_root=tree) == 0
    assert cpl.main(["--fix"], repo_root=tree) == 0


def _unit_with_body(tmp_path, body, name="talos-vms"):
    unit = tmp_path / "infrastructure" / "units" / "public" / "proxmox" / name
    unit.mkdir(parents=True)
    (unit / "terragrunt.hcl").write_text(body, encoding="utf-8")
    return unit


def test_extract_blocks_keyword_absent_returns_empty():
    assert cpl._extract_blocks("hello world", "terraform") == []


def test_extract_blocks_keyword_without_brace_no_hang():
    assert cpl._extract_blocks("terraform requires providers", "terraform") == []


def test_extract_blocks_unclosed_brace_no_hang():
    assert cpl._extract_blocks("terraform {", "terraform") == []


def test_parse_required_providers_skips_entry_without_source(tmp_path):
    cat = _catalog(
        tmp_path,
        tf=textwrap.dedent(
            """\
            terraform {
              required_providers {
                tool_rest = {
                  version = "9.9.9"
                }
              }
            }
            """
        ),
    )
    assert parse_required_providers(cat) == {}


def test_parse_required_providers_unclosed_block(tmp_path):
    cat = _catalog(tmp_path, tf="terraform {\n  required_providers {\n")
    assert parse_required_providers(cat) == {}


def test_parse_lock_file_provider_without_version(tmp_path):
    lock = tmp_path / "lock.hcl"
    lock.write_text(
        'provider "registry.opentofu.org/opentofu/null" {\n  hashes = ["h1:x"]\n}\n',
        encoding="utf-8",
    )
    assert parse_lock_file(lock) == {}


def test_find_units_ignores_terraform_block_without_source(tmp_path):
    _catalog(tmp_path)
    unit = _unit_with_body(
        tmp_path,
        'terraform {\n  required_version = ">= 1.8"\n}\n',
        name="nosource",
    )
    parent = tmp_path / "infrastructure" / "units" / "public" / "proxmox"
    found = find_units(parent)
    assert unit not in found


def test_check_unit_no_source_block_is_warning(tmp_path):
    _catalog(tmp_path)
    unit = _unit_with_body(tmp_path, 'terraform {\n  required_version = ">= 1.8"\n}\n')
    result = check_unit(unit, tmp_path)
    assert result.drift == []
    assert any("no terraform source block" in line for line in result.warnings)


def test_check_unit_unverifiable_constraint_is_warning(tmp_path):
    _catalog(
        tmp_path,
        tf=textwrap.dedent(
            """\
            terraform {
              required_providers {
                proxmox = {
                  source  = "telmate/proxmox"
                  version = "whatever"
                }
              }
            }
            """
        ),
    )
    unit = tmp_path / "infrastructure" / "units" / "public" / "proxmox" / "talos-vms"
    unit.mkdir(parents=True)
    (unit / "terragrunt.hcl").write_text(
        'terraform {\n  source = "${get_repo_root()}//infrastructure/catalogs/public/proxmox-vm"\n}\n',
        encoding="utf-8",
    )
    (unit / ".terraform.lock.hcl").write_text(LOCK_RC10, encoding="utf-8")
    result = check_unit(unit, tmp_path)
    assert result.drift == []
    assert any("unverifiable constraint" in line for line in result.warnings)


def test_run_terragrunt_init_stdout(monkeypatch):
    def fake_run(cmd, cwd, check):
        assert cmd == ["terragrunt", "init", "-upgrade", "-input=false"]
        return subprocess.CompletedProcess(cmd, 0)

    monkeypatch.setattr(cpl.subprocess, "run", fake_run)
    assert cpl.run_terragrunt_init(Path("/tmp")) is True


def test_run_terragrunt_init_nonzero(monkeypatch):
    def fake_run(cmd, cwd, check):
        return subprocess.CompletedProcess(cmd, 1)

    monkeypatch.setattr(cpl.subprocess, "run", fake_run)
    assert cpl.run_terragrunt_init(Path("/tmp")) is False


def test_main_prints_warnings(tmp_path, capsys):
    _catalog(tmp_path)
    unit = _unit(tmp_path, source="${get_original_terragrunt_dir()}/x")
    assert cpl.main(["--check"], repo_root=tmp_path) == 0
    out = capsys.readouterr().out
    assert "WARNING" in out and str(unit) in out


def test_cli_entrypoint(tmp_path):
    tree = _drift_tree(tmp_path)
    lock = (
        tree
        / "infrastructure"
        / "units"
        / "public"
        / "proxmox"
        / "talos-vms"
        / ".terraform.lock.hcl"
    )
    lock.write_text(LOCK_RC10, encoding="utf-8")
    script = Path(cpl.__file__)
    proc = subprocess.run(
        [sys.executable, str(script), "--check"],
        cwd=tree,
        capture_output=True,
        text=True,
        check=False,
    )
    assert proc.returncode == 0
    assert "unit(s) with drift" in proc.stdout
