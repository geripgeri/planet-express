#!/usr/bin/env python3
"""
Converts plain ADR references (e.g., ADR-001) into Markdown links.
Skips references already inside links, backticks, or code blocks.
Leaves ADR in the title line (e.g., "# ADR-001: ...") unlinked.
"""

import pathlib
import re
import sys
from collections.abc import Callable

ADR_DIR = pathlib.Path("docs/decisions")
# Matches ADR-001 through ADR-999 or ADR-H
ADR_RE = re.compile(r"(?<!\w)(ADR-(?:\d{3}|H))(?!\w)")
# Matches code blocks, inline code, or existing Markdown links
SKIP_RE = re.compile(r"```.*?```|`[^`]*`|\[.*?\]\(.*?\)", re.DOTALL)


def build_adr_map(adr_dir: pathlib.Path, logger: Callable = print) -> dict[str, str]:
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


def linkify_content(
    content: str,
    mapping: dict[str, str],
    source_path: pathlib.Path,
    adr_dir: pathlib.Path = ADR_DIR,
) -> str:
    """
    Replaces ADR references with links, protecting code and existing links.
    Logic: Find 'skip' patterns or 'ADR' patterns. If it's a skip pattern, return as is.

    If an ADR appears as the very first token on a top-level title line (i.e., the line
    starts with "# " followed immediately by "ADR-..."), do NOT convert it to a link.
    This preserves titles like "# ADR-001: Title" as plain text.

    Links are relative to source_path so they resolve correctly from any directory.
    """
    combined_re = re.compile(f"({SKIP_RE.pattern})|({ADR_RE.pattern})", re.DOTALL)

    def replace(match: re.Match) -> str:
        skipped_segment = match.group(1)
        adr_id = match.group(2)

        if skipped_segment:
            return skipped_segment

        # adr_id is guaranteed to be non-None here because the regex will always
        # match one of the two groups when sub() calls this function
        start_pos = match.start(2)
        line_start = content.rfind("\n", 0, start_pos) + 1

        if content.startswith("# ", line_start):
            return adr_id

        if adr_id in mapping:
            target = adr_dir / mapping[adr_id]
            rel = (
                pathlib.Path(target).relative_to(source_path.parent)
                if target.is_relative_to(source_path.parent)
                else pathlib.Path(_relpath(target, source_path.parent))
            )
            return f"[{adr_id}]({rel.as_posix()})"

        return adr_id

    return combined_re.sub(replace, content)


def _relpath(target: pathlib.Path, anchor: pathlib.Path) -> str:
    """Return a POSIX-style relative path from anchor directory to target."""
    # Convert both to absolute paths based on CWD so the arithmetic is correct
    # even when the script is run from an arbitrary working directory.
    abs_target = target.resolve()
    abs_anchor = anchor.resolve()
    parts_target = abs_target.parts
    parts_anchor = abs_anchor.parts

    # Find common prefix length
    common = 0
    for a, b in zip(parts_target, parts_anchor):
        if a == b:
            common += 1
        else:
            break

    up = len(parts_anchor) - common
    down = parts_target[common:]
    return "/".join([".."] * up + list(down))


def process_file(
    path: pathlib.Path,
    mapping: dict[str, str],
    adr_dir: pathlib.Path = ADR_DIR,
    logger: Callable = print,
) -> bool:
    """Reads, transforms, and writes file if changes were made."""
    try:
        content = path.read_text(encoding="utf-8")
        new_content = linkify_content(content, mapping, path, adr_dir)

        if content != new_content:
            path.write_text(new_content, encoding="utf-8")
            logger(f"[INFO] Updated {path}")
            return True
    except (OSError, UnicodeDecodeError) as e:
        logger(f"[WARN] Failed to process {path}: {e}")

    return False


def main(
    argv: list[str] | None = None,
    adr_dir: pathlib.Path = ADR_DIR,
    logger: Callable = print,
) -> int:
    paths = [pathlib.Path(f) for f in (argv if argv is not None else sys.argv[1:])]
    mapping = build_adr_map(adr_dir, logger)

    if not mapping:
        logger("[WARN] No ADRs found; nothing to link.")
        return 0

    changed_any = False
    for path in paths:
        if path.suffix.lower() == ".md":
            if process_file(path, mapping, adr_dir, logger):
                changed_any = True
        else:
            logger(f"[DEBUG] Skipping non-markdown: {path}")

    if changed_any:
        logger("[INFO] Files updated. Please re-stage and commit.")
        return 1

    return 0


if __name__ == "__main__":  # pragma: no cover
    main()
