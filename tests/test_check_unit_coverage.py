"""Guard: every .tf resource tree in infrastructure/ maps to a Terragrunt unit.

A .tf file must sit in a catalog directory that at least one unit references,
or in the exempted live-test harness. Anything else is resource code that
bypasses the Terragrunt structure (rule IaC-01).
"""

from scripts.check_unit_coverage import main


def make_catalog(root, name):
    catalog = root / "infrastructure" / "catalogs" / "public" / name
    catalog.mkdir(parents=True)
    (catalog / "main.tf").write_text('resource "local_file" "x" {}\n')
    return catalog


def make_unit(root, unit_name, catalog_name):
    unit = root / "infrastructure" / "units" / "public" / "group" / unit_name
    unit.mkdir(parents=True)
    (unit / "terragrunt.hcl").write_text(
        'terraform {\n  description = "unused"\n}\n'
        'terraform {\n  source = "${get_repo_root()}'
        f'/infrastructure/catalogs/public/{catalog_name}"\n}}\n'
    )
    return unit


def run(capsys, tmp_path, argv=None):
    code = main(argv if argv is not None else [], repo_root=tmp_path)
    return code, capsys.readouterr().out


def test_empty_infrastructure_passes(capsys, tmp_path):
    (tmp_path / "infrastructure").mkdir()
    code, out = run(capsys, tmp_path)
    assert code == 0, out


def test_recorded_gap_catalog_is_exempt(capsys, tmp_path):
    (tmp_path / "infrastructure" / "catalogs" / "public" / "adguard-config").mkdir(
        parents=True
    )
    (
        tmp_path
        / "infrastructure"
        / "catalogs"
        / "public"
        / "adguard-config"
        / "main.tf"
    ).write_text('resource "local_file" "a" {}\n')
    code, out = run(capsys, tmp_path)
    assert code == 0, out


def test_exemption_is_catalog_scoped(capsys, tmp_path):
    make_catalog(tmp_path, "lxc")
    code, out = run(capsys, tmp_path)
    assert code == 1
    assert "no unit references" in out


def test_catalog_with_consuming_unit_passes(capsys, tmp_path):
    make_catalog(tmp_path, "lxc")
    make_unit(tmp_path, "garage-lxc", "lxc")
    code, out = run(capsys, tmp_path)
    assert code == 0, out


def test_orphan_catalog_fails(capsys, tmp_path):
    make_catalog(tmp_path, "lxc")
    code, out = run(capsys, tmp_path)
    assert code == 1
    assert "no unit references" in out


def test_stray_tf_outside_catalogs_fails(capsys, tmp_path):
    stray = tmp_path / "infrastructure" / "units" / "public" / "group" / "stray"
    stray.mkdir(parents=True)
    (stray / "main.tf").write_text('resource "null_resource" "x" {}\n')
    code, out = run(capsys, tmp_path)
    assert code == 1
    assert "no matching unit" in out


def test_allowlisted_harness_ignored(capsys, tmp_path):
    make_catalog(tmp_path, "lxc")
    make_unit(tmp_path, "garage-lxc", "lxc")
    harness = tmp_path / "infrastructure" / "tests" / "live" / "lxc"
    harness.mkdir(parents=True)
    (harness / "main.tf").write_text('resource "local_file" "h" {}\n')
    code, out = run(capsys, tmp_path)
    assert code == 0, out


def test_generated_stack_copies_ignored(capsys, tmp_path):
    make_catalog(tmp_path, "lxc")
    make_unit(tmp_path, "garage-lxc", "lxc")
    stack = tmp_path / "infrastructure" / "stacks" / "public" / "garage"
    stack.mkdir(parents=True)
    (stack / "terragrunt.stack.hcl").write_text('unit {\n  path = "."\n}\n')
    generated = stack / ".terragrunt-stack" / "unit"
    generated.mkdir(parents=True)
    (generated / "terragrunt.hcl").write_text('terraform {\n  source = "x"\n}\n')
    (generated / "main.tf").write_text('resource "local_file" "y" {}\n')
    code, out = run(capsys, tmp_path)
    assert code == 0, out


def test_local_repo_root_source_counts_as_match(capsys, tmp_path):
    make_catalog(tmp_path, "garage")
    unit = tmp_path / "infrastructure" / "units" / "public" / "garage" / "k8s-backup"
    unit.mkdir(parents=True)
    (unit / "terragrunt.hcl").write_text(
        "locals {\n  repo_root = get_repo_root()\n}\n"
        'terraform {\n  source = "${local.repo_root}'
        '//infrastructure/catalogs/public/garage"\n}\n'
    )
    code, out = run(capsys, tmp_path)
    assert code == 0, out


def test_unknown_local_source_does_not_save_orphan(capsys, tmp_path):
    make_catalog(tmp_path, "lxc")
    unit = tmp_path / "infrastructure" / "units" / "public" / "group" / "cold"
    unit.mkdir(parents=True)
    (unit / "terragrunt.hcl").write_text(
        'terraform {\n  source = "${local.somewhere}/catalogs/public/lxc"\n}\n'
    )
    code, out = run(capsys, tmp_path)
    assert code == 1
    assert "no unit references" in out


def test_unresolvable_unit_source_does_not_save_orphan(capsys, tmp_path):
    orphan = tmp_path / "infrastructure" / "catalogs" / "public" / "lxc"
    orphan.mkdir(parents=True)
    (orphan / "main.tf").write_text('resource "local_file" "x" {}\n')
    unit = tmp_path / "infrastructure" / "units" / "public" / "group" / "cold"
    unit.mkdir(parents=True)
    (unit / "terragrunt.hcl").write_text(
        'terraform {\n  source = "${path_relative_to_include()}/../lxc"\n}\n'
    )
    code, out = run(capsys, tmp_path)
    assert code == 1
    assert "no unit references" in out
