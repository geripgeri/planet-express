#!/usr/bin/env python3
"""Map every .tf file under infrastructure/ to a Terragrunt unit.

Rule IaC-01 gate: a .tf file is a resource expressed as code only when it
sits in a catalog directory that at least one unit references. Files outside
catalogs, or inside orphaned catalogs, are drift. The live-test harness dirs
are code-under-test, not provisioned resources, so they are exempt.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

_repo_root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(_repo_root))

from scripts.check_provider_locks import (
    _SRC_RE,
    _extract_blocks,
    find_units,
    resolve_catalog_dir,
)

EXEMPT_PREFIXES: tuple[str, ...] = ("infrastructure/tests/",)
# Recorded orphans: materialised code waiting for wiring, not deletions.
# adguard-config has a written module and no consuming unit yet; the wiring is
# the DNS-02 gap TODO in docs/runbooks/authentik-deploy.md (rulebook gap found
# 2026-09-22). Remove the entry when the adguard unit lands.
EXEMPT_CATALOGS: tuple[str, ...] = ("infrastructure/catalogs/public/adguard-config",)
GENERATED_DIRS = {".terragrunt-stack", ".terragrunt-cache", ".terraform"}
ROOT_LOCALS_RE = re.compile(
    r"^[ \t]*(\w+)[ \t]*=[ \t]*get_repo_root\(\)[ \t]*$", re.MULTILINE
)


def collect_tf_files(infra_dir: Path) -> list[Path]:
    """All .tf files under infrastructure/, ignoring generated Terragrunt trees."""
    return [
        path
        for path in infra_dir.rglob("*.tf")
        if not GENERATED_DIRS.intersection(path.parts)
    ]


def resolve_referenced_catalogs(units_dir: Path, repo_root: Path) -> set[Path]:
    referenced: set[Path] = set()
    for unit_dir in find_units(units_dir):
        text = (unit_dir / "terragrunt.hcl").read_text(encoding="utf-8")
        root_locals = set(ROOT_LOCALS_RE.findall(text))
        for block in _extract_blocks(text, "terraform"):
            if source := _SRC_RE.search(block):
                expr = source.group(1)
                for name in root_locals:
                    expr = expr.replace(f"${{local.{name}}}", "${get_repo_root()}")
                catalog = resolve_catalog_dir(unit_dir, expr, repo_root)
                if catalog is not None:
                    referenced.add(catalog.resolve())
    return referenced


def check_all(repo_root: Path) -> list[str]:
    infra_dir = repo_root / "infrastructure"
    referenced = resolve_referenced_catalogs(infra_dir / "units", repo_root)
    problems: list[str] = []
    catalog_dirs: set[Path] = set()
    for tf_path in collect_tf_files(infra_dir):
        rel = tf_path.relative_to(repo_root).as_posix()
        if rel.startswith(EXEMPT_PREFIXES):
            continue
        if not rel.startswith("infrastructure/catalogs/"):
            problems.append(
                f"{rel}: outside catalogs, no matching unit (move the resources "
                "into a catalog module and reference it from a unit)"
            )
            continue
        catalog_dirs.add(tf_path.parent)
    for catalog_dir in sorted(catalog_dirs):
        if catalog_dir.relative_to(repo_root).as_posix().startswith(EXEMPT_CATALOGS):
            continue
        if catalog_dir.resolve() not in referenced:
            problems.append(
                f"{catalog_dir.relative_to(repo_root).as_posix()}: no unit "
                "references this catalog"
            )
    return sorted(problems)


def main(argv: list[str] | None = None, repo_root: Path | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Check that every .tf resource tree has a matching unit."
    )
    parser.parse_args(argv)
    root = repo_root or Path.cwd()
    problems = check_all(root)
    for line in problems:
        print(f"DRIFT: {line}")
    print(f"\n{len(problems)} problem(s)")
    return 1 if problems else 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())  # pragma: no cover
