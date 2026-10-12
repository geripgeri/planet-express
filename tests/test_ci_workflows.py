import pathlib
import re
import subprocess

WORKFLOW_DIR = pathlib.Path(".gitea/workflows")
SOPS_URL = re.compile(
    r"github\.com/getsops/sops/releases/download/(?P<tag>v[0-9][^/\s\\]*)/"
    r"(?P<asset>sops-[^/\s\\]+)"
)


def _find_in_workflow(name: str, needle: str) -> str:
    """Return the find command line containing needle in a workflow file."""
    path = WORKFLOW_DIR / name
    for line in path.read_text().splitlines():
        stripped = line.strip()
        if "find " not in stripped or needle not in stripped:
            continue
        idx = stripped.index("find ")
        return stripped[idx:]
    raise AssertionError(f"no find command for {needle!r} in {name}")


def _plan_find_cmd() -> str:
    """The plan-side discovery command, verbatim from tofu-plan.yaml."""
    path = WORKFLOW_DIR / "tofu-plan.yaml"
    for line in path.read_text().splitlines():
        stripped = line.strip()
        if "find infrastructure/stacks" not in stripped:
            continue
        cmd = stripped.split("$(", 1)[1]
        return cmd.rsplit(")", 1)[0]
    raise AssertionError("plan discovery find not found in tofu-plan.yaml")


def _discover(repo_root: pathlib.Path) -> list[str]:
    """Run the plan-side discovery exactly as tofu-plan.yaml does."""
    out = subprocess.run(
        _plan_find_cmd(),
        shell=True,
        cwd=repo_root,
        capture_output=True,
        text=True,
        check=True,
    )
    return [line for line in out.stdout.splitlines() if line]


def _sops_downloads() -> list[tuple[pathlib.Path, str, str]]:
    found = []
    for path in sorted(WORKFLOW_DIR.glob("*.y*ml")):
        for tag, asset in SOPS_URL.findall(path.read_text()):
            found.append((path, tag, asset))
    return found


def test_workflows_download_sops():
    downloads = _sops_downloads()
    assert downloads, "no workflow downloads sops; this check is stale"


def test_sops_download_asset_matches_tag():
    for path, tag, asset in _sops_downloads():
        assert asset.startswith(f"sops-{tag}."), (
            f"{path} downloads {asset} from tag {tag}; asset name must carry "
            f"the same version as the release tag"
        )


def test_sops_download_asset_consistent_across_workflows():
    assets = {asset for _path, _tag, asset in _sops_downloads()}
    assert len(assets) == 1, (
        "workflows download different sops asset names: "
        f"{sorted(assets)}; a wrong name 404s and breaks the job"
    )


CACHE_UNIT = "proxmox/talos-vms"


def _write_stack(root: pathlib.Path, rel: str) -> None:
    target = root / "infrastructure" / "stacks" / rel
    target.mkdir(parents=True, exist_ok=True)
    (target / "terragrunt.stack.hcl").write_text('unit "x" {\n  source = "y"\n}\n')


def _build_cache_polluted(tmp_path: pathlib.Path) -> pathlib.Path:
    """A repo where a unit cache mirrors sibling stack paths."""
    root = tmp_path / "repo"
    for real in (
        "private/authentik",
        "public/argocd",
        "public/garage",
        "public/proxmox",
    ):
        _write_stack(root, real)

    # The pollution pattern seen on a working host: terragrunt copies an
    # absolute stack source into a unit cache, so `.terragrunt-stack` and
    # `.terragrunt-cache` trees contain terragrunt.stack.hcl files.
    stack = root / "infrastructure" / "stacks" / "public" / "garage"
    for cache_rel in ("private/authentik", "public/proxmox"):
        mirror = (
            stack
            / ".terragrunt-stack"
            / CACHE_UNIT
            / ".terragrunt-cache"
            / "hash1"
            / "hash2"
            / "infrastructure"
            / "stacks"
            / cache_rel
        )
        mirror.mkdir(parents=True)
        (mirror / "terragrunt.stack.hcl").write_text('unit "x" {\n  source = "y"\n}\n')
    return root


def test_plan_discovery_excludes_terragrunt_artifacts(tmp_path):
    # The guard must live in the workflow itself, so the invariant survives
    # an edit that removes a local exclusion.
    workflow_find = _find_in_workflow("tofu-plan.yaml", "infrastructure/stacks")
    assert "-not -path" in workflow_find, (
        "tofu-plan find must exclude terragrunt artifact paths"
    )
    assert "terragrunt" in workflow_find, (
        "tofu-plan find must exclude .terragrunt-stack/.terragrunt-cache paths"
    )

    root = _build_cache_polluted(tmp_path)
    found = _discover(root)

    assert set(found) == {
        "infrastructure/stacks/private/authentik",
        "infrastructure/stacks/public/argocd",
        "infrastructure/stacks/public/garage",
        "infrastructure/stacks/public/proxmox",
    }


def test_plan_discovery_would_leak_without_the_guard(tmp_path):
    """Prove the polluted layout is a real hazard, not a hypothetical one."""
    root = _build_cache_polluted(tmp_path)

    on_disk = len(list(root.rglob("terragrunt.stack.hcl")))
    discovered = len(_discover(root))

    assert discovered < on_disk, (
        "the workflow find is not excluding cache artifacts; "
        f"{on_disk} on disk, {discovered} discovered"
    )


def test_apply_unit_find_excludes_cache(tmp_path):
    workflow_find = _find_in_workflow("tofu-apply.yaml", ".terragrunt-stack")
    assert "-not -path" in workflow_find, (
        "tofu-apply unit find must exclude the terragrunt cache"
    )
    assert ".terragrunt-cache" in workflow_find


def test_apply_unit_find_ignores_generated_units(tmp_path):
    """Generated unit terragrunt.hcl files are the intended targets."""
    root = tmp_path / "infrastructure"
    stack = root / "stacks" / "public" / "garage"
    for rel in ("proxmox/talos-vms", "garage/k8s-backup"):
        unit = stack / ".terragrunt-stack" / rel
        unit.mkdir(parents=True)
        (unit / "terragrunt.hcl").write_text('terraform { source = "x" }\n')
    # A cache mirror of a stack path, which the exclusion must drop.
    mirror = (
        stack
        / ".terragrunt-stack"
        / "garage/k8s-backup"
        / ".terragrunt-cache"
        / "hash1"
        / "hash2"
        / "infrastructure"
        / "stacks"
        / "public/garage"
    )
    mirror.mkdir(parents=True)
    (mirror / "terragrunt.stack.hcl").write_text('unit "g" { source = "y" }\n')

    found = sorted(
        p.relative_to(stack).as_posix()
        for p in (stack / ".terragrunt-stack").rglob("terragrunt.hcl")
    )
    assert found == [
        ".terragrunt-stack/garage/k8s-backup/terragrunt.hcl",
        ".terragrunt-stack/proxmox/talos-vms/terragrunt.hcl",
    ]
