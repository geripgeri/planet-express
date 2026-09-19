#!/usr/bin/env python3
"""Compute and fix sha256 checksum pins for binary-pinned dependencies.

Renovate cannot hash release artifacts, so Renovate-raised binary bumps arrive
with a stale checksum. This module downloads the pinned binary, runs it, and
computes the sha256 the release channel does not publish. Table-driven for
future binary pins; garage is the first entry.

Usage:
  python3 scripts/update_artifact_checksums.py --fix
  python3 scripts/update_artifact_checksums.py --verify
"""

from __future__ import annotations

import hashlib
import os
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parents[1]

BINARIES: dict[str, dict] = {
    "Deuxfleurs/garage": {
        "file": "ansible/roles/garage/defaults/main.yaml",
        "version_re": re.compile(r'garage_version:\s*"(\d+\.\d+\.\d+)"'),
        "checksum_re": re.compile(r'(garage_checksum:\s*"sha256:)([0-9a-f]{64})(")'),
        "url_template": "https://garagehq.deuxfleurs.fr/_releases/v{version}/x86_64-unknown-linux-musl/garage",
        "verify_args": ["--version"],
    },
}


def sha256_of(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _pattern(value):
    """Return a compiled pattern from a compiled or raw-string pattern."""
    return value if isinstance(value, re.Pattern) else re.compile(value)


def extract_version(text: str, entry: dict) -> str:
    m = _pattern(entry["version_re"]).search(text)
    if not m:
        raise ValueError("no version line matched")
    return m.group(1)


def extract_checksum(text: str, entry: dict) -> str:
    m = _pattern(entry["checksum_re"]).search(text)
    if not m:
        raise ValueError("no checksum line matched")
    return m.group(2)


def url_for(entry: dict, version: str) -> str:
    return entry["url_template"].format(version=version)


def _default_fetch(url: str) -> bytes:
    with urllib.request.urlopen(url, timeout=60) as resp:
        return resp.read()


def fetch(url: str, fetch_fn=None) -> bytes:
    return (fetch_fn or _default_fetch)(url)


def _default_run(prog: Path, args: list[str]) -> str:
    proc = subprocess.run(
        [str(prog), *args], capture_output=True, text=True, timeout=120, check=False
    )
    return proc.stdout + proc.stderr


def run_verify(prog: Path, version: str, args: list[str], run_fn=None) -> bool:
    """Run the binary and report whether the pinned version appears in output."""
    output = (run_fn or _default_run)(prog, args)
    return bool(output) and version in output


def checksum_for(entry: dict, version: str, fetch_fn=None, run_fn=None) -> str:
    """Download the pinned version, verify it runs, return 'sha256:<hex>'."""
    data = fetch(url_for(entry, version), fetch_fn=fetch_fn)
    verify_args = entry.get("verify_args")
    if verify_args:
        fd, name = tempfile.mkstemp()
        path = Path(name)
        try:
            with os.fdopen(fd, "wb") as fh:
                fh.write(data)
            path.chmod(0o755)
            if not run_verify(path, version, verify_args, run_fn=run_fn):
                raise ValueError(
                    f"binary for version {version} failed {verify_args[0]}"
                )
        finally:
            path.unlink()
    return "sha256:" + sha256_of(data)


def replace_checksum(text: str, checksum: str, entry: dict) -> str:
    return _pattern(entry["checksum_re"]).sub(
        lambda m: m.group(1) + checksum[len("sha256:") :] + m.group(3), text, count=1
    )


def process_file(path: Path, entry: dict, fetch_fn=None, run_fn=None) -> bool:
    """Rewrite the checksum line when stale; True when it changed."""
    text = path.read_text()
    checksum = checksum_for(
        entry, extract_version(text, entry), fetch_fn=fetch_fn, run_fn=run_fn
    )
    if extract_checksum(text, entry) == checksum[len("sha256:") :]:
        return False
    path.write_text(replace_checksum(text, checksum, entry))
    return True


def verify_file(path: Path, entry: dict, fetch_fn=None, run_fn=None) -> bool:
    text = path.read_text()
    checksum = checksum_for(
        entry, extract_version(text, entry), fetch_fn=fetch_fn, run_fn=run_fn
    )
    return extract_checksum(text, entry) == checksum[len("sha256:") :]


def main(argv, binaries=None, root=None, fetch_fn=None, run_fn=None) -> int:
    """--fix writes stale checksums; --verify reports staleness. 0 ok, 1 fail, 2 usage."""
    binaries = BINARIES if binaries is None else binaries
    root = _REPO_ROOT if root is None else root
    if len(argv) != 1 or argv[0] not in ("--fix", "--verify"):
        print("usage: update_artifact_checksums.py --fix|--verify", file=sys.stderr)
        return 2
    writing = argv[0] == "--fix"
    failed = False
    for name, entry in binaries.items():
        path = root / entry["file"]
        try:
            changed = (
                process_file(path, entry, fetch_fn=fetch_fn, run_fn=run_fn)
                if writing
                else not verify_file(path, entry, fetch_fn=fetch_fn, run_fn=run_fn)
            )
            if changed and not writing:
                failed = True
            print(
                f"{name}: {'fixed' if changed and writing else 'STALE' if changed else 'ok'}"
            )
        except (
            ValueError,
            OSError,
            subprocess.SubprocessError,
            urllib.error.URLError,
        ) as exc:
            print(f"{name}: error: {exc}", file=sys.stderr)
            failed = True
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
