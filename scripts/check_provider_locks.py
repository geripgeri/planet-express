#!/usr/bin/env python3
"""Detect OpenTofu provider lock drift in Terragrunt units and optionally fix it."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

_VERSION_RE = re.compile(r"^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?$")


def parse_version(version: str) -> tuple[int, int, int, str | None] | None:
    m = _VERSION_RE.match(version.strip())
    if not m:
        return None
    return (int(m.group(1)), int(m.group(2)), int(m.group(3)), m.group(4))


def _prerelease_less(a: str | None, b: str | None) -> bool:
    if a is None:
        return False
    if b is None:
        return True
    a_parts = a.split(".")
    b_parts = b.split(".")
    for x, y in zip(a_parts, b_parts):
        if x != y:
            return x < y
    return len(a_parts) < len(b_parts)


def compare_versions(a: str, b: str) -> int | None:
    pa, pb = parse_version(a), parse_version(b)
    if pa is None or pb is None:
        return None
    if pa[:3] != pb[:3]:
        return -1 if pa[:3] < pb[:3] else 1
    if pa[3] == pb[3]:
        return 0
    return -1 if _prerelease_less(pa[3], pb[3]) else 1


def _next_block(version: str) -> tuple[int, int, int]:
    parts = version.strip().split("-", 1)[0].split(".")
    nums = [int(p) for p in parts[:3]]
    if len(nums) == 1:
        return (nums[0] + 1, 0, 0)
    if len(nums) == 2:
        return (nums[0] + 1, 0, 0)
    return (nums[0], nums[1] + 1, 0)


def _normalize(version: str) -> str:
    code, sep, pre = version.strip().partition("-")
    nums = code.split(".")
    while len(nums) < 3:
        nums.append("0")
    return ".".join(nums[:3]) + (sep + pre if sep else "")


_OPS = re.compile(r"^(~>|>=|<=|!=|=|>|<)?\s*(\S+)$")


def _extract_blocks(text: str, keyword: str) -> list[str]:
    blocks: list[str] = []
    idx = 0
    while True:
        start = text.find(keyword, idx)
        if start < 0:
            break
        brace = text.find("{", start + len(keyword))
        if brace < 0:
            idx = start + len(keyword)
            continue
        depth = 0
        i = brace
        while i < len(text):
            if text[i] == "{":
                depth += 1
            elif text[i] == "}":
                depth -= 1
                if depth == 0:
                    blocks.append(text[brace + 1 : i])
                    idx = i + 1
                    break
            i += 1
        else:
            idx = len(text)
    return blocks


_ENTRY_RE = re.compile(r"(\w+)\s*=\s*\{(?P<body>[^{}]*)\}")
_SRC_RE = re.compile(r'source\s*=\s*"([^"]+)"')
_VER_RE = re.compile(r'version\s*=\s*"([^"]+)"')


def parse_required_providers(catalog_dir: Path) -> dict[str, str | None]:
    providers: dict[str, str | None] = {}
    for tf_file in sorted(catalog_dir.glob("*.tf")):
        text = tf_file.read_text(encoding="utf-8")
        for block in _extract_blocks(text, "required_providers"):
            for entry in _ENTRY_RE.finditer(block):
                src = _SRC_RE.search(entry.group("body"))
                if not src:
                    continue
                ver = _VER_RE.search(entry.group("body"))
                providers[src.group(1)] = ver.group(1) if ver else None
    return providers


_LOCK_PROV_RE = re.compile(
    r'provider\s+"registry\.opentofu\.org/([^"]+)"\s*\{(?P<body>[^{}]*)\}',
    re.DOTALL,
)


def parse_lock_file(lock_path: Path) -> dict[str, str]:
    text = lock_path.read_text(encoding="utf-8")
    versions: dict[str, str] = {}
    for match in _LOCK_PROV_RE.finditer(text):
        ver = _VER_RE.search(match.group("body"))
        if ver:
            versions[match.group(1)] = ver.group(1)
    return versions


def resolve_catalog_dir(
    unit_dir: Path, source_expr: str, repo_root: Path
) -> Path | None:
    expr = source_expr
    if expr.startswith("${get_repo_root()}"):
        expr = str(repo_root) + expr[len("${get_repo_root()}") :]
    elif "${" in expr or "(" in expr:
        return None
    path = Path(expr.replace("//", "/"))
    if not path.is_absolute():
        path = (unit_dir / path).resolve()
    return path if path.is_dir() else None


def find_units(units_dir: Path) -> list[Path]:
    units: list[Path] = []
    for tg_file in units_dir.rglob("terragrunt.hcl"):
        if ".terragrunt-stack" in tg_file.parts:
            continue
        text = tg_file.read_text(encoding="utf-8")
        for block in _extract_blocks(text, "terraform"):
            if _SRC_RE.search(block):
                units.append(tg_file.parent)
                break
    return sorted(units)


@dataclass
class UnitResult:
    unit_dir: Path
    drift: list[str]
    warnings: list[str]


def check_unit(unit_dir: Path, repo_root: Path) -> UnitResult:
    drift: list[str] = []
    warnings: list[str] = []
    text = (unit_dir / "terragrunt.hcl").read_text(encoding="utf-8")
    source_expr = None
    for block in _extract_blocks(text, "terraform"):
        src = _SRC_RE.search(block)
        if src:
            source_expr = src.group(1)
            break
    if source_expr is None:
        warnings.append(f"{unit_dir}: no terraform source block; skipped")
        return UnitResult(unit_dir, drift, warnings)
    catalog_dir = resolve_catalog_dir(unit_dir, source_expr, repo_root)
    if catalog_dir is None:
        warnings.append(f"{unit_dir}: cannot resolve source {source_expr!r}; skipped")
        return UnitResult(unit_dir, drift, warnings)
    constrained = {
        fqdn: ver
        for fqdn, ver in parse_required_providers(catalog_dir).items()
        if ver is not None
    }
    lock_path = unit_dir / ".terraform.lock.hcl"
    if not lock_path.exists():
        drift.append(
            f"missing lock file (catalog {catalog_dir.name} requires "
            f"{len(constrained)} constrained provider(s))"
        )
        return UnitResult(unit_dir, drift, warnings)
    locked = parse_lock_file(lock_path)
    for fqdn, constraint in sorted(constrained.items()):
        ver = locked.get(fqdn)
        if ver is None:
            drift.append(f"{fqdn}: missing from lock (constraint {constraint})")
            continue
        ok = satisfies_constraint(ver, constraint)
        if ok is False:
            drift.append(f"{fqdn}: locked {ver}, constraint {constraint}")
        elif ok is None:
            warnings.append(f"{fqdn}: unverifiable constraint {constraint!r}")
    return UnitResult(unit_dir, drift, warnings)


def check_all(repo_root: Path) -> list[UnitResult]:
    units_dir = repo_root / "infrastructure" / "units"
    return [check_unit(unit, repo_root) for unit in find_units(units_dir)]


def satisfies_constraint(locked: str, constraint: str) -> bool | None:
    for clause in (c.strip() for c in constraint.split(",") if c.strip()):
        m = _OPS.match(clause)
        if not m:
            return None
        op = m.group(1) or "="
        ver = _normalize(m.group(2))
        cmp = compare_versions(locked, ver)
        if cmp is None:
            if op == "!=":
                continue
            return None
        if op == "~>":
            if (
                cmp < 0
                or compare_versions(
                    locked, ".".join(str(x) for x in _next_block(m.group(2)))
                )
                >= 0
            ):
                return False
        elif (
            op == "="
            and cmp != 0
            or op == "!="
            and cmp == 0
            or op == ">="
            and cmp < 0
            or op == "<="
            and cmp > 0
            or op == ">"
            and cmp <= 0
            or op == "<"
            and cmp >= 0
        ):
            return False
    return True


def run_terragrunt_init(unit_dir: Path) -> bool:
    return (
        subprocess.run(
            ["terragrunt", "init", "-upgrade", "-input=false"],
            cwd=unit_dir,
            check=False,
        ).returncode
        == 0
    )


def main(argv: list[str] | None = None, repo_root: Path | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Check OpenTofu provider lock drift in Terragrunt units."
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--check", action="store_true", help="report drift and exit 1 if any (default)"
    )
    mode.add_argument(
        "--fix",
        action="store_true",
        help="run terragrunt init -upgrade on drifting units",
    )
    args = parser.parse_args(argv)
    root = repo_root or Path.cwd()
    results = check_all(root)
    failures = 0
    for result in results:
        for warning in result.warnings:
            print(f"WARNING: {warning}")
        if result.drift:
            print(f"DRIFT: {result.unit_dir}")
            for line in result.drift:
                print(f"  - {line}")
            if not args.fix:
                print("  fix: terragrunt init -upgrade -input=false")
                failures += 1
    if not args.fix:
        drift_count = sum(bool(r.drift) for r in results)
        print(f"\n{drift_count} unit(s) with drift")
        return 1 if failures else 0
    fixed = 0
    for result in results:
        if not result.drift:
            continue
        if run_terragrunt_init(result.unit_dir):
            after = check_unit(result.unit_dir, root)
            if after.drift:
                print(f"still drifting after fix: {after.unit_dir}")
                for line in after.drift:
                    print(f"  - {line}")
                failures += 1
            else:
                fixed += 1
                print(f"fixed: {result.unit_dir}")
        else:
            print(f"terragrunt init failed: {result.unit_dir}")
            failures += 1
    clean = sum(not r.drift for r in results)
    print(f"\n{fixed} fixed, {clean + fixed} clean, {failures} failed")
    return 0 if not failures else 1


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())  # pragma: no cover
