"""Tests for the tftest orphan sweep script."""

import runpy
import sys
import urllib.error
from pathlib import Path

import pytest

from scripts.ci_sweep_test_guests import (
    RESERVED_VMID_FLOOR,
    _request,
    auth_header,
    destroy_guest,
    fetch_guests,
    find_stale_guests,
    main,
)

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "ci_sweep_test_guests.py"


def _guest(vmid, name, uptime, gtype="qemu"):
    return {
        "vmid": vmid,
        "name": name,
        "uptime": uptime,
        "node": "zoidberg",
        "type": gtype,
    }


class TestFindStaleGuests:
    def test_old_prefixed_guest_is_flagged(self):
        guests = [_guest(5910, "tftest-orphan", 7 * 3600)]
        assert find_stale_guests(guests, max_age_hours=6) == guests

    def test_young_prefixed_guest_is_kept(self):
        guests = [_guest(5900, "tftest-live-vm", 60)]
        assert find_stale_guests(guests, max_age_hours=6) == []

    def test_exact_age_boundary_is_flagged(self):
        guests = [_guest(5900, "tftest-live-lxc", 6 * 3600)]
        assert len(find_stale_guests(guests, max_age_hours=6)) == 1

    def test_unprefixed_low_vmid_prod_like_guest_never_flagged(self):
        guests = [
            _guest(500, "talos-worker-03", 999 * 3600),
            _guest(110, "garage-01", 999 * 3600, gtype="lxc"),
        ]
        assert find_stale_guests(guests, max_age_hours=6) == []

    def test_high_vmid_without_prefix_still_flagged(self):
        guests = [_guest(RESERVED_VMID_FLOOR + 50, "leftover", 8 * 3600)]
        assert len(find_stale_guests(guests, max_age_hours=6)) == 1

    def test_missing_uptime_defaults_to_zero(self):
        guests = [{"vmid": 5900, "name": "tftest-x", "node": "zoidberg", "type": "lxc"}]
        assert find_stale_guests(guests, max_age_hours=6) == []


class TestAuthHeader:
    def test_header_format_matches_pve_api_token_scheme(self):
        header = auth_header("ci-runner@pve!tftest", "s3cret")
        assert header == "PVEAPIToken=ci-runner@pve!tftest=s3cret"


class TestFetchGuests:
    def test_reads_members_from_ci_tests_pool(self, monkeypatch):
        captured = {}

        def fake_request(base_url, token_id, token_secret, path, **kwargs):
            captured["path"] = path
            return {
                "poolid": "ci-tests",
                "members": [
                    {
                        "vmid": 5900,
                        "name": "tftest-live-vm",
                        "uptime": 60,
                        "node": "zoidberg",
                        "type": "qemu",
                    }
                ],
            }

        monkeypatch.setattr("scripts.ci_sweep_test_guests._request", fake_request)
        guests = fetch_guests(
            "https://zoidberg.local:8006", "ci-runner@pve!tftest", "s3cret"
        )
        assert captured["path"] == "/api2/json/pools/ci-tests"
        assert guests == [
            {
                "vmid": 5900,
                "name": "tftest-live-vm",
                "uptime": 60,
                "node": "zoidberg",
                "type": "qemu",
            }
        ]

    def test_empty_members_lists_to_empty_guests(self, monkeypatch):
        monkeypatch.setattr(
            "scripts.ci_sweep_test_guests._request",
            lambda base_url, token_id, token_secret, path: {
                "poolid": "ci-tests",
                "members": [],
            },
        )
        assert (
            fetch_guests(
                "https://zoidberg.local:8006", "ci-runner@pve!tftest", "s3cret"
            )
            == []
        )


@pytest.mark.parametrize(
    ("bad_url"),
    ["ftp://192.0.2.1:8006", "not-a-url"],
)
def test_normalize_base_url_rejects_non_http(bad_url):
    from scripts.ci_sweep_test_guests import normalize_base_url

    with pytest.raises(ValueError):
        normalize_base_url(bad_url)


def test_normalize_base_url_appends_slash():
    from scripts.ci_sweep_test_guests import normalize_base_url

    assert normalize_base_url("https://192.0.2.1:8006") == "https://192.0.2.1:8006/"


def test_strips_trailing_api2_json():
    from scripts.ci_sweep_test_guests import normalize_base_url

    assert (
        normalize_base_url("https://192.0.2.1:8006/api2/json")
        == "https://192.0.2.1:8006/"
    )


def test_strips_trailing_api2_json_with_slash():
    from scripts.ci_sweep_test_guests import normalize_base_url

    assert (
        normalize_base_url("https://192.0.2.1:8006/api2/json/")
        == "https://192.0.2.1:8006/"
    )


def test_does_not_strip_nested_api2_json():
    from scripts.ci_sweep_test_guests import normalize_base_url

    assert normalize_base_url("https://192.0.2.1:8006/api2/json/nodes") == (
        "https://192.0.2.1:8006/api2/json/nodes/"
    )


class _FakeResponse:
    def __init__(self, payload: bytes):
        self._payload = payload

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def read(self):
        return self._payload


class TestRequest:
    def test_builds_authenticated_get_and_returns_data(self, monkeypatch):
        captured = {}

        def fake_urlopen(req, timeout=30.0, context=None):
            captured["url"] = req.full_url
            captured["method"] = req.method
            captured["header"] = req.get_header("Authorization")
            captured["timeout"] = timeout
            return _FakeResponse(b'{"data": {"poolid": "ci-tests", "members": []}}')

        monkeypatch.setattr(
            "scripts.ci_sweep_test_guests.urllib.request.urlopen", fake_urlopen
        )
        result = _request(
            "https://zoidberg.local:8006",
            "ci-runner@pve!tftest",
            "s3cret",
            "/api2/json/pools/ci-tests",
        )
        assert result == {"poolid": "ci-tests", "members": []}
        assert captured["url"] == "https://zoidberg.local:8006/api2/json/pools/ci-tests"
        assert captured["method"] == "GET"
        assert captured["header"] == "PVEAPIToken=ci-runner@pve!tftest=s3cret"
        assert captured["timeout"] == 30.0

    def test_returns_whole_payload_when_data_key_absent(self, monkeypatch):
        monkeypatch.setattr(
            "scripts.ci_sweep_test_guests.urllib.request.urlopen",
            lambda req, timeout=30.0, context=None: _FakeResponse(b'{"ok": true}'),
        )
        assert _request(
            "https://zoidberg.local:8006", "t", "s", "/api2/json/hello"
        ) == {"ok": True}

    def test_http_error_raises_runtime_error_with_hint(self, monkeypatch):
        def boom(req, timeout=30.0, context=None):
            raise urllib.error.HTTPError(
                req.full_url, 501, "Method not implemented", {}, None
            )

        monkeypatch.setattr("scripts.ci_sweep_test_guests.urllib.request.urlopen", boom)
        with pytest.raises(RuntimeError, match="501"):
            _request(
                "https://zoidberg.local:8006", "t", "s", "/api2/json/pools/ci-tests"
            )


class TestDestroyGuest:
    def test_destroys_qemu_via_node_endpoint(self, monkeypatch):
        captured = {}

        def fake_request(
            base_url, token_id, token_secret, path, method="GET", **kwargs
        ):
            captured["path"] = path
            captured["method"] = method

        monkeypatch.setattr("scripts.ci_sweep_test_guests._request", fake_request)
        destroy_guest(
            "https://zoidberg.local:8006",
            "t",
            "s",
            {"vmid": 5910, "name": "tftest-x", "node": "zoidberg", "type": "qemu"},
        )
        assert captured["path"] == "/api2/json/nodes/zoidberg/qemu/5910"
        assert captured["method"] == "DELETE"

    def test_destroys_lxc_via_node_endpoint(self, monkeypatch):
        captured = {}

        def fake_request(
            base_url, token_id, token_secret, path, method="GET", **kwargs
        ):
            captured["path"] = path
            captured["method"] = method

        monkeypatch.setattr("scripts.ci_sweep_test_guests._request", fake_request)
        destroy_guest(
            "https://zoidberg.local:8006",
            "t",
            "s",
            {"vmid": 5901, "name": "tftest-y", "node": "zoidberg", "type": "lxc"},
        )
        assert captured["path"] == "/api2/json/nodes/zoidberg/lxc/5901"
        assert captured["method"] == "DELETE"


def _main_args(*extra_flags, **overrides):
    base = {
        "--base-url": "https://zoidberg.local:8006",
        "--token-id": "ci-runner@pve!tftest",
        "--token-secret": "s3cret",
        "--max-age-hours": "6",
    }
    base.update(overrides)
    args = [item for pair in base.items() for item in pair]
    args.extend(extra_flags)
    return args


class TestMain:
    def test_dry_run_reports_without_deleting(self, monkeypatch, capsys):
        guests = [_guest(5900, "tftest-live-vm", 7 * 3600)]
        monkeypatch.setattr(
            "scripts.ci_sweep_test_guests.fetch_guests", lambda *a: guests
        )
        monkeypatch.setattr(
            "scripts.ci_sweep_test_guests.find_stale_guests", lambda g, **kw: g
        )
        destroyed = []
        monkeypatch.setattr(
            "scripts.ci_sweep_test_guests.destroy_guest",
            lambda *a, **kw: destroyed.append(a),
        )
        assert main(_main_args("--dry-run")) == 0
        out = capsys.readouterr().out
        assert '"WOULD-DESTROY"' in out
        assert "tftest-live-vm" in out
        assert "no stale test guests found" not in out
        assert destroyed == []

    def test_destroys_stale_guests_when_not_dry_run(self, monkeypatch, capsys):
        guests = [_guest(5900, "tftest-orphan", 7 * 3600)]
        monkeypatch.setattr(
            "scripts.ci_sweep_test_guests.fetch_guests", lambda *a: guests
        )
        monkeypatch.setattr(
            "scripts.ci_sweep_test_guests.find_stale_guests", lambda g, **kw: g
        )
        destroyed = []
        monkeypatch.setattr(
            "scripts.ci_sweep_test_guests.destroy_guest",
            lambda b, t, s, g: destroyed.append(g),
        )
        assert main(_main_args()) == 0
        assert destroyed == guests
        out = capsys.readouterr().out
        assert '"DESTROY"' in out

    def test_no_stale_prints_clean_message(self, monkeypatch, capsys):
        monkeypatch.setattr("scripts.ci_sweep_test_guests.fetch_guests", lambda *a: [])
        monkeypatch.setattr(
            "scripts.ci_sweep_test_guests.find_stale_guests", lambda g, **kw: []
        )
        assert main(_main_args()) == 0
        assert "no stale test guests found" in capsys.readouterr().out


def test_run_as_main_program(monkeypatch):
    monkeypatch.setattr(
        "scripts.ci_sweep_test_guests.urllib.request.urlopen",
        lambda req, timeout=30.0, context=None: _FakeResponse(
            b'{"data": {"poolid": "ci-tests", "members": []}}'
        ),
    )
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "ci_sweep_test_guests.py",
            "--base-url",
            "https://zoidberg.local:8006",
            "--token-id",
            "ci-runner@pve!tftest",
            "--token-secret",
            "s3cret",
            "--dry-run",
        ],
    )
    with pytest.raises(SystemExit) as exc:
        runpy.run_path(str(SCRIPT), run_name="__main__")
    assert exc.value.code == 0
