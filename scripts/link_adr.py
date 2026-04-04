#!/usr/bin/env python3
"""
Converts plain ADR references (e.g., ADR-001) into Markdown links.
Skips references already inside links, backticks, or code blocks.
"""

import pathlib
import re
import sys
from typing import Dict, List, Optional, Callable

ADR_DIR = pathlib.Path("docs/decisions")
# Matches ADR-001 through ADR-999 or ADR-H
ADR_RE = re.compile(r"\b(ADR-(?:\d{3}|H))\b")
# Matches code blocks, inline code, or existing Markdown links
SKIP_RE = re.compile(r"```.*?```|`[^`]*`|\[.*?\]\(.*?\)", re.DOTALL)


def build_adr_map(adr_dir: pathlib.Path, logger: Callable = print) -> Dict[str, str]:
    """Scans the directory for ADR files and returns a mapping of ID to filename."""
    mapping = {}
    if not adr_dir.exists():
        return mapping

    for f in adr_dir.glob("ADR-*.md"):
        match = ADR_RE.search(f.name)
        if match:
            mapping[match.group(1)] = f.name

    ids = sorted(mapping.keys(), key=lambda x: (x != "ADR-H", x))
    logger(f"[INFO] Found {len(mapping)} ADRs: {', '.join(ids)}")
    return mapping


def linkify_content(content: str, mapping: Dict[str, str]) -> str:
    """
    Replaces ADR references with links, protecting code and existing links.
    Logic: Find 'skip' patterns or 'ADR' patterns. If it's a skip pattern, return as is.
    """
    # Combine patterns: Group 1 is stuff to skip, Group 2 is the ADR to link
    combined_re = re.compile(f"({SKIP_RE.pattern})|({ADR_RE.pattern})", re.DOTALL)

    def replace(match: re.Match) -> str:
        skipped_segment = match.group(1)
        adr_id = match.group(2)

        if skipped_segment:
            return skipped_segment

        if adr_id in mapping:
            return f"[{adr_id}](docs/decisions/{mapping[adr_id]})"

        return adr_id

    return combined_re.sub(replace, content)


def process_file(path: pathlib.Path, mapping: Dict[str, str], logger: Callable = print) -> bool:
    """Reads, transforms, and writes file if changes were made."""
    try:
        content = path.read_text(encoding="utf-8")
        new_content = linkify_content(content, mapping)

        if content != new_content:
            path.write_text(new_content, encoding="utf-8")
            logger(f"[INFO] Updated {path}")
            return True
    except Exception as e:
        logger(f"[WARN] Failed to process {path}: {e}")

    return False


def main(argv: Optional[List[str]] = None, adr_dir: pathlib.Path = ADR_DIR, logger: Callable = print) -> int:
    paths = [pathlib.Path(f) for f in (argv if argv is not None else sys.argv[1:])]
    mapping = build_adr_map(adr_dir, logger)

    if not mapping:
        logger("[WARN] No ADRs found; nothing to link.")
        return 0

    changed_any = False
    for path in paths:
        if path.suffix.lower() == ".md":
            if process_file(path, mapping, logger):
                changed_any = True
        else:
            logger(f"[DEBUG] Skipping non-markdown: {path}")

    if changed_any:
        logger("[INFO] Files updated. Please re-stage and commit.")
        return 1

    return 0


if __name__ == "__main__":  # pragma: no cover
    main()
