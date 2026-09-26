import pathlib
import re

WORKFLOW_DIR = pathlib.Path(".gitea/workflows")
SOPS_URL = re.compile(
    r"github\.com/getsops/sops/releases/download/(?P<tag>v[0-9][^/\s\\]*)/"
    r"(?P<asset>sops-[^/\s\\]+)"
)


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
