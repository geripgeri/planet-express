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
# Matches ADR-001 through ADR-999 or ADR-H. The trailing lookahead also
# excludes '-', so ids inside longer hyphenated tokens (e.g. filenames like
# docs/decisions/ADR-001-project-goals.md) are not rewritten.
ADR_RE = re.compile(r"(?<!\w)(ADR-(?:\d{3}|H))(?![\w-])")
# Extracts the id from an ADR filename (ADR-001-project-goals.md). Anchored
# at the start and WITHOUT the trailing boundary: the remainder of a
# filename legitimately continues with '-'.
FILENAME_ADR_RE = re.compile(r"^(ADR-(?:\d{3}|H))")
# Inline constructs that protect their content: inline code and existing
# Markdown links. Fenced code blocks are handled by _fenced_regions below.
SKIP_RE = re.compile(r"`[^`]*`|\[.*?\]\(.*?\)")
# CommonMark fenced-code delimiter: 3+ backticks or tildes, indented at
# most 3 spaces. Group 1 is the fence run, group 2 the line remainder
# (info string on openers, must be blank on closers).
FENCE_RE = re.compile(r"^ {0,3}(`{3,}|~{3,})(.*)$", re.MULTILINE)


def _fenced_regions(content: str) -> list[tuple[int, int]]:
    """
    Return character spans covered by fenced code blocks.

    Implements the CommonMark fenced-code rule: an opening fence of N
    backticks (or tildes) closes only on a same-character fence of length
    >= N with no trailing info string. Backtick openers must not carry a
    backtick in their info string. An unclosed fence protects to EOF.

    Raises ValueError if control bytes \\x00 or \\x01 appear in the input;
    they are reserved as mask tokens by linkify_content.
    """
    if "\x00" in content or "\x01" in content:
        raise ValueError("input contains control bytes reserved for masking")

    regions: list[tuple[int, int]] = []
    opener: tuple[str, int] | None = None
    region_start = 0

    for match in FENCE_RE.finditer(content):
        run, rest = match.group(1), match.group(2)
        char, length = run[0], len(run)

        if opener is None:
            if char == "`" and "`" in rest:
                continue
            opener = (char, length)
            region_start = match.start()
        elif char == opener[0] and length >= opener[1] and not rest.strip():
            regions.append((region_start, match.end()))
            opener = None

    if opener is not None:
        regions.append((region_start, len(content)))

    return regions


def build_adr_map(adr_dir: pathlib.Path, logger: Callable = print) -> dict[str, str]:
    """Scans the directory for ADR files and returns a mapping of ID to filename."""
    mapping = {}
    if not adr_dir.exists():
        return mapping

    for f in adr_dir.glob("ADR-*.md"):
        match = FILENAME_ADR_RE.search(f.name)
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
    Logic: Fenced code blocks are masked out first via _fenced_regions, so
    their content is invisible to the substitution. Then find inline 'skip'
    patterns or 'ADR' patterns; skip patterns are returned unchanged.

    If an ADR appears as the very first token on a top-level title line (i.e., the line
    starts with "# " followed immediately by "ADR-..."), do NOT convert it to a link.
    This preserves titles like "# ADR-001: Title" as plain text.

    Links are relative to source_path so they resolve correctly from any directory.
    """
    combined_re = re.compile(f"({SKIP_RE.pattern})|({ADR_RE.pattern})", re.DOTALL)

    # Collapse fenced regions to sentinel tokens so the regex never sees
    # their content; restore the originals after substitution.
    placeholders: dict[str, str] = {}
    parts: list[str] = []
    last = 0
    for idx, (start, end) in enumerate(_fenced_regions(content)):
        parts.append(content[last:start])
        token = f"\x00{idx}\x01"
        placeholders[token] = content[start:end]
        parts.append(token)
        last = end
    parts.append(content[last:])
    masked_content = "".join(parts)

    def replace(match: re.Match) -> str:
        skipped_segment = match.group(1)
        adr_id = match.group(2)

        if skipped_segment:
            return skipped_segment

        # adr_id is guaranteed to be non-None here because the regex will always
        # match one of the two groups when sub() calls this function
        start_pos = match.start(2)
        line_start = masked_content.rfind("\n", 0, start_pos) + 1

        if masked_content.startswith("# ", line_start):
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

    result = combined_re.sub(replace, masked_content)
    for token, original in placeholders.items():
        result = result.replace(token, original)
    return result


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
