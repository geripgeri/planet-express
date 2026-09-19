"""Tests for scripts.update_artifact_checksums."""

import runpy
import sys
from pathlib import Path
from unittest import mock

import pytest

from scripts.update_artifact_checksums import (
    checksum_for,
    extract_checksum,
    extract_version,
    fetch,
    main,
    process_file,
    replace_checksum,
    run_verify,
    sha256_of,
    url_for,
    verify_file,
)

BIN = bytes.fromhex("00112233445566778899aabbccddeeff")
HEX = sha256_of(BIN)

TEXT = (
    'garage_version: "2.3.0"\n'
    'garage_checksum: "sha256:' + "a" * 64 + '"\n'
    'garage_binary_url: "https://example.com/{version}/garage"\n'
)


def fake_fetch(url: str) -> bytes:
    return BIN


def fake_run(prog: Path, args: list[str]) -> str:
    return "garage 2.3.0 (v2.3.0)\n"


def garage_entry(**overrides) -> dict:
    entry = {
        "file": "ansible/roles/garage/defaults/main.yaml",
        "version_re": r'garage_version:\s*"(\d+\.\d+\.\d+)"',
        "checksum_re": r'(garage_checksum:\s*"sha256:)([0-9a-f]{64})(")',
        "url_template": "https://example.com/{version}/garage",
        "verify_args": ["--version"],
    }
    entry.update(overrides)
    return entry


def test_sha256_of_deterministic():
    assert sha256_of(b"abc") == sha256_of(b"abc")
    assert sha256_of(b"abc") != sha256_of(b"abx")


def test_extract_version_matches():
    assert extract_version(TEXT, garage_entry()) == "2.3.0"


def test_extract_version_no_match_raises():
    with pytest.raises(ValueError):
        extract_version('garage_version: "nope"', garage_entry())


def test_extract_checksum_matches():
    assert extract_checksum(TEXT, garage_entry()) == "a" * 64


def test_extract_checksum_no_match_raises():
    with pytest.raises(ValueError):
        extract_checksum('garage_checksum: "sha256:0000"', garage_entry())


def test_url_for_interpolates_template():
    entry = garage_entry(url_template="https://example.com/v{version}/bin")
    assert url_for(entry, "2.4.1") == "https://example.com/v2.4.1/bin"


def test_fetch_fake_opener():
    assert fetch("https://example.com/any", fetch_fn=fake_fetch) == BIN


def test_fetch_default_opener_reads_response():
    with mock.patch(
        "scripts.update_artifact_checksums.urllib.request.urlopen"
    ) as open_mock:
        open_mock.return_value.__enter__.return_value.read.return_value = b"payload"
        assert fetch("https://example.com/real") == b"payload"
        open_mock.assert_called_once_with("https://example.com/real", timeout=60)


def test_main_guard_executes_main(capsys):
    sys.argv = ["update_artifact_checksums.py", "--bogus"]
    with pytest.raises(SystemExit) as exc:
        runpy.run_path("scripts/update_artifact_checksums.py", run_name="__main__")
    assert exc.value.code == 2
    assert "usage:" in capsys.readouterr().err


def test_fetch_custom_error_surfaces():
    def explode(url: str) -> bytes:
        raise PermissionError("denied")

    with pytest.raises(PermissionError):
        fetch("https://example.com/blocked", fetch_fn=explode)


def test_run_verify_version_present():
    assert run_verify(Path("/tmp/garage"), "2.3.0", ["--version"], run_fn=fake_run)


def test_run_verify_version_absent():
    def other(prog: Path, args: list[str]) -> str:
        return "usage: garage [OPTIONS]"

    assert not run_verify(Path("/tmp/garage"), "2.3.0", ["--version"], run_fn=other)


def test_run_verify_empty_output_false():
    def empty(prog: Path, args: list[str]) -> str:
        return ""

    assert not run_verify(Path("/tmp/garage"), "2.3.0", ["--version"], run_fn=empty)


def test_checksum_for_skips_verify_when_no_verify_args():
    entry = garage_entry()
    entry.pop("verify_args")
    assert checksum_for(entry, "2.3.0", fetch_fn=fake_fetch) == "sha256:" + HEX


def test_checksum_for_verifies_when_args_present():
    result = checksum_for(garage_entry(), "2.3.0", fetch_fn=fake_fetch, run_fn=fake_run)
    assert result == "sha256:" + HEX


def test_checksum_for_verify_failure_raises():
    def bad_run(prog: Path, args: list[str]) -> str:
        return "not garage at all"

    with pytest.raises(ValueError):
        checksum_for(garage_entry(), "2.3.0", fetch_fn=fake_fetch, run_fn=bad_run)


def test_checksum_for_real_exec_close_before_exec():
    script = b"#!/bin/sh\necho 2.3.0\n"

    def script_fetch(url: str) -> bytes:
        return script

    result = checksum_for(garage_entry(), "2.3.0", fetch_fn=script_fetch)
    assert result == "sha256:" + sha256_of(script)


def test_replace_checksum_writes_new_value():
    out = replace_checksum(TEXT, "sha256:" + HEX, garage_entry())
    assert 'garage_checksum: "sha256:' + HEX + '"' in out
    assert 'garage_version: "2.3.0"' in out


def test_process_file_changes_when_stale(tmp_path):
    target = tmp_path / "main.yaml"
    target.write_text(TEXT)
    entry = garage_entry(file=str(target))
    assert process_file(target, entry, fetch_fn=fake_fetch, run_fn=fake_run) is True
    assert extract_checksum(target.read_text(), entry) == HEX


def test_process_file_noop_when_clean(tmp_path):
    clean = TEXT.replace("a" * 64, HEX)
    target = tmp_path / "main.yaml"
    target.write_text(clean)
    entry = garage_entry(file=str(target))
    assert process_file(target, entry, fetch_fn=fake_fetch, run_fn=fake_run) is False
    assert target.read_text() == clean


def test_verify_file_true_when_clean(tmp_path):
    clean = TEXT.replace("a" * 64, HEX)
    target = tmp_path / "main.yaml"
    target.write_text(clean)
    entry = garage_entry(file=str(target))
    assert verify_file(target, entry, fetch_fn=fake_fetch, run_fn=fake_run) is True


def test_verify_file_false_when_stale(tmp_path):
    target = tmp_path / "main.yaml"
    target.write_text(TEXT)
    entry = garage_entry(file=str(target))
    assert verify_file(target, entry, fetch_fn=fake_fetch, run_fn=fake_run) is False


def test_main_fix_writes_files(tmp_path):
    target = tmp_path / "main.yaml"
    target.write_text(TEXT)
    binaries = {"garage": garage_entry(file=str(target))}
    assert main(["--fix"], binaries=binaries, fetch_fn=fake_fetch, run_fn=fake_run) == 0
    assert extract_checksum(target.read_text(), garage_entry()) == HEX


def test_main_fix_second_run_noop(tmp_path):
    target = tmp_path / "main.yaml"
    target.write_text(TEXT)
    binaries = {"garage": garage_entry(file=str(target))}
    assert main(["--fix"], binaries=binaries, fetch_fn=fake_fetch, run_fn=fake_run) == 0
    assert main(["--fix"], binaries=binaries, fetch_fn=fake_fetch, run_fn=fake_run) == 0


def test_main_verify_stale_returns_one(tmp_path):
    target = tmp_path / "main.yaml"
    target.write_text(TEXT)
    binaries = {"garage": garage_entry(file=str(target))}
    assert (
        main(["--verify"], binaries=binaries, fetch_fn=fake_fetch, run_fn=fake_run) == 1
    )


def test_main_verify_clean_returns_zero(tmp_path):
    clean = TEXT.replace("a" * 64, HEX)
    target = tmp_path / "main.yaml"
    target.write_text(clean)
    binaries = {"garage": garage_entry(file=str(target))}
    assert (
        main(["--verify"], binaries=binaries, fetch_fn=fake_fetch, run_fn=fake_run) == 0
    )


def test_main_empty_table_noop():
    assert main(["--fix"], binaries={}) == 0
    assert main(["--verify"], binaries={}) == 0


def test_main_unknown_flag_returns_two():
    assert main(["--bogus"]) == 2


def test_main_missing_file_returns_one(tmp_path):
    binaries = {"garage": garage_entry(file=str(tmp_path / "absent.yaml"))}
    assert main(["--fix"], binaries=binaries, fetch_fn=fake_fetch, run_fn=fake_run) == 1
