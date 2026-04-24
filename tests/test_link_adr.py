import pathlib
import pytest
import sys
from scripts.link_adr import main, build_adr_map, linkify_content, _relpath


@pytest.fixture
def workspace(tmp_path):
    """
    Sets up a temporary filesystem with a standard Architecture Decision Record
    (ADR) directory structure and sample files.
    """
    adr_dir = tmp_path / "docs" / "decisions"
    adr_dir.mkdir(parents=True)

    # Create sample ADR files to test different naming patterns
    (adr_dir / "ADR-001-base.md").write_text("Content")
    (adr_dir / "ADR-H-hard.md").write_text("Content")

    return tmp_path, adr_dir


def test_build_adr_map(workspace):
    """Verifies that the ADR scanner correctly maps IDs to their filenames."""
    _, adr_dir = workspace
    mapping = build_adr_map(adr_dir, logger=lambda x: None)

    assert mapping["ADR-001"] == "ADR-001-base.md"
    assert mapping["ADR-H"] == "ADR-H-hard.md"


def test_build_adr_map_dir_not_exists(tmp_path):
    """Ensures the scanner returns an empty mapping if the ADR directory is missing."""
    fake_dir = tmp_path / "not_here"
    mapping = build_adr_map(fake_dir, logger=lambda x: None)
    assert mapping == {}


def test_build_adr_map_regex_no_match(workspace):
    """Ensures files that don't match the required ADR naming convention are ignored."""
    _, adr_dir = workspace

    # Create a file that matches the glob (*.md) but fails the ID regex
    (adr_dir / "ADR-X.md").write_text("Invalid ID")

    mapping = build_adr_map(adr_dir, logger=lambda x: None)
    assert "ADR-X" not in mapping


def test_linkify_logic(tmp_path):
    """
    Tests the core substitution logic, ensuring it handles edge cases like
    code blocks, existing links, and missing references.
    Source is at the repo root so expected links are docs/decisions/…
    """
    adr_dir = tmp_path / "docs" / "decisions"
    adr_dir.mkdir(parents=True)
    mapping = {"ADR-001": "ADR-001.md"}
    source = tmp_path / "README.md"

    cases = [
        # Standard replacement
        ("Check ADR-001", "Check [ADR-001](docs/decisions/ADR-001.md)"),
        # Inline code should be ignored
        ("`ADR-001` in code", "`ADR-001` in code"),
        # Existing markdown links should be ignored
        ("[Already linked](ADR-001)", "[Already linked](ADR-001)"),
        # IDs not found in the mapping should remain plain text
        ("ADR-999 (missing)", "ADR-999 (missing)"),
        # Fenced code blocks should be ignored
        ("```\nADR-001 block\n```", "```\nADR-001 block\n```"),
    ]

    for text_in, expected in cases:
        assert linkify_content(text_in, mapping, source, adr_dir) == expected


def test_linkify_with_parentheses(tmp_path):
    """Verify that ADR references inside parentheses are properly linked."""
    adr_dir = tmp_path / "docs" / "decisions"
    adr_dir.mkdir(parents=True)
    mapping = {"ADR-001": "ADR-001.md"}
    source = tmp_path / "README.md"

    cases = [
        ("(see ADR-001)", "(see [ADR-001](docs/decisions/ADR-001.md))"),
        ("ADR-001.", "[ADR-001](docs/decisions/ADR-001.md)."),
        ("ADR-001,", "[ADR-001](docs/decisions/ADR-001.md),"),
        ("ADR-001:", "[ADR-001](docs/decisions/ADR-001.md):"),
    ]

    for text_in, expected in cases:
        assert linkify_content(text_in, mapping, source, adr_dir) == expected


def test_linkify_from_adr_same_dir(tmp_path):
    """
    ADR inside docs/decisions/ referencing another ADR in the same directory.
    Target IS relative to source.parent, so relative_to() is used (not _relpath).
    Expected link is just the bare filename with no directory prefix.
    """
    adr_dir = tmp_path / "docs" / "decisions"
    adr_dir.mkdir(parents=True)
    mapping = {"ADR-001": "ADR-001-base.md"}
    source = adr_dir / "ADR-002-something.md"

    result = linkify_content("See ADR-001", mapping, source, adr_dir)
    assert result == "See [ADR-001](ADR-001-base.md)"


def test_linkify_from_sibling_dir(tmp_path):
    """
    File in a sibling directory (docs/other/) referencing an ADR in docs/decisions/.
    Target is NOT relative to source.parent, so _relpath is called and produces
    a ../ traversal to reach the decisions directory.
    """
    adr_dir = tmp_path / "docs" / "decisions"
    adr_dir.mkdir(parents=True)
    sibling = tmp_path / "docs" / "other"
    sibling.mkdir()
    mapping = {"ADR-001": "ADR-001-base.md"}
    source = sibling / "guide.md"

    result = linkify_content("See ADR-001", mapping, source, adr_dir)
    assert result == "See [ADR-001](../decisions/ADR-001-base.md)"


def test_relpath_direct():
    """
    Unit-tests _relpath directly for all common-prefix traversal cases,
    including diverging siblings that exercise the loop break.
    """
    # Target directly inside anchor — no traversal needed
    assert _relpath(pathlib.Path("/a/b/c/file.md"), pathlib.Path("/a/b/c")) == "file.md"

    # Sibling directory — one level up then down (exercises the break in the loop)
    assert (
        _relpath(pathlib.Path("/a/b/c/file.md"), pathlib.Path("/a/b/other"))
        == "../c/file.md"
    )

    # Deeper nesting — multiple levels up
    assert (
        _relpath(pathlib.Path("/a/b/c/file.md"), pathlib.Path("/a/x/y"))
        == "../../b/c/file.md"
    )


def test_main_workflow(workspace, capsys):
    """Tests the full end-to-end execution on a file that needs updates."""
    root, adr_dir = workspace
    test_md = root / "test.md"
    test_md.write_text("Ref ADR-001")

    # main returns 1 when changes are performed
    ret = main(argv=[str(test_md)], adr_dir=adr_dir, logger=print)

    assert ret == 1
    assert "[ADR-001](docs/decisions/ADR-001-base.md)" in test_md.read_text()


def test_main_no_mapping(tmp_path, capsys):
    """Ensures the script exits gracefully if no ADR files are found to link to."""
    empty_dir = tmp_path / "empty_docs"
    empty_dir.mkdir()

    ret = main(argv=["file.md"], adr_dir=empty_dir, logger=print)

    captured = capsys.readouterr()
    assert ret == 0
    assert "No ADRs found" in captured.out


def test_main_no_changes(workspace):
    """Ensures the script returns 0 if a file is scanned but no links need updating."""
    root, adr_dir = workspace
    test_md = root / "test.md"
    test_md.write_text("No ADRs here")

    ret = main(argv=[str(test_md)], adr_dir=adr_dir, logger=lambda x: None)
    assert ret == 0


def test_non_markdown_skipped(workspace, capsys):
    """Checks that the script ignores files that do not have a .md extension."""
    root, adr_dir = workspace
    test_txt = root / "test.txt"
    test_txt.write_text("ADR-001")

    main(argv=[str(test_txt)], adr_dir=adr_dir, logger=print)
    captured = capsys.readouterr()
    assert "Skipping non-markdown" in captured.out


def test_unreadable_file(workspace, monkeypatch):
    """Ensures the script doesn't crash if it encounters a file it cannot read."""
    root, adr_dir = workspace
    test_md = root / "broken.md"
    test_md.write_text("ADR-001")

    def mock_read_error(*args, **kwargs):
        raise PermissionError("Locked")

    # Simulate a file system permission error
    monkeypatch.setattr(pathlib.Path, "read_text", mock_read_error)

    ret = main(argv=[str(test_md)], adr_dir=adr_dir, logger=lambda x: None)
    assert ret == 0  # Should fail silently or log and continue


def test_sys_argv_integration(workspace, monkeypatch):
    """Tests that the script correctly falls back to sys.argv when no arguments are passed."""
    root, adr_dir = workspace
    test_md = root / "file.md"
    test_md.write_text("ADR-001")

    # Mock CLI arguments: script_name path/to/file
    monkeypatch.setattr(sys, "argv", ["script.py", str(test_md)])

    ret = main(argv=None, adr_dir=adr_dir, logger=lambda x: None)
    assert ret == 1


def test_title_line_adr_unlinked(workspace):
    """
    Verify that ADR references in Markdown title lines are NOT converted to links,
    while the same ADR referenced elsewhere in the document IS converted.

    This tests the special case where "# ADR-001: Title" should remain as plain text
    to preserve readable document titles, while "Ref ADR-001" becomes a clickable link.
    """
    root, adr_dir = workspace
    test_md = root / "title.md"
    test_md.write_text("# ADR-001: Title\n\nRef ADR-001\n")

    ret = main(argv=[str(test_md)], adr_dir=adr_dir, logger=lambda x: None)

    assert ret == 1
    out = test_md.read_text()
    assert out.splitlines()[0].startswith("# ADR-001:")
    assert "Ref [ADR-001](docs/decisions/ADR-001-base.md)" in out
