"""Guard for the live-harness pool-enrol payload.

The provisioner enrols each tftest guest into the Proxmox `ci-tests`
pool so the sweep sees leftovers. It once sent a prefixed VMID with
POST; PVE has no POST handler on /pools/{poolid}, so the nightly died
at enrol. The tests extract the exact `python3 -c` payload from each
committed main.tf and run it against a mock of the /pools/{poolid}
surface (GET/PUT/DELETE only).
"""

import json
import re
import subprocess
import sys
import threading
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import pytest

REPO = Path(__file__).resolve().parents[1]
HARNESSES = {
    "lxc": REPO / "infrastructure" / "tests" / "live" / "lxc" / "main.tf",
    "vm": REPO / "infrastructure" / "tests" / "live" / "vm" / "main.tf",
}
POOL_PATH = "/api2/json/pools/ci-tests"
TOKEN_ID = "ci-runner@pve!tftest"
TOKEN_SECRET = "unused-mock-secret"
EXPECTED_HEADER = f"PVEAPIToken={TOKEN_ID}={TOKEN_SECRET}"


def enrol_payload(path):
    """Extract the exact python3 -c code the local-exec provisioner runs."""
    text = path.read_text(encoding="utf-8")
    start = text.index("python3 -c '") + len("python3 -c '")
    end = re.search(r"\n\s*'\s+\"\$\{trim\(", text[start:]).start()
    return text[start : start + end]


@pytest.fixture
def pve_server():
    hits = []

    class _Handler(BaseHTTPRequestHandler):
        def _handle(self):
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length).decode()
            path = urlparse(self.path).path
            hits.append((self.command, path, body, self.headers.get("Authorization")))
            if path != POOL_PATH:
                self.send_response(501)
                self.end_headers()
                self.wfile.write(b'{"errors":{}}')
                return
            if self.command == "PUT":
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(b'{"data":null}')
                return
            # Any other verb, like a real PVE router: no POST on /pools/{poolid}.
            self.send_response(501)
            self.end_headers()
            self.wfile.write(
                f"501 Method '{self.command} /pools/ci-tests' not implemented\n".encode()
            )

        do_GET = do_PUT = do_POST = _handle

        def log_message(self, *_args):
            pass

    httpd = HTTPServer(("127.0.0.1", 0), _Handler)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    try:
        yield httpd, hits
    finally:
        httpd.shutdown()


@pytest.mark.parametrize("harness", ["lxc", "vm"])
def test_enrol_uses_put_with_plain_vmid(harness, pve_server):
    """The payload must succeed against the real /pools/{poolid} surface."""
    httpd, hits = pve_server
    code = enrol_payload(HARNESSES[harness])
    base = f"http://127.0.0.1:{httpd.server_address[1]}/"

    run = subprocess.run(
        [sys.executable, "-c", code, base, "5900", TOKEN_ID, TOKEN_SECRET],
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )

    assert run.returncode == 0, run.stderr
    # Exactly one write: a PUT (PVE has no POST handler on /pools/{poolid}).
    assert len(hits) == 1
    command, path, body, header = hits[0]
    assert (command, path) == ("PUT", POOL_PATH)
    # pve-vmid-list: plain numeric VMID, no qemu:/lxc: prefix.
    assert parse_qs(body) == {"vms": ["5900"]}
    assert header == EXPECTED_HEADER


def test_enrol_payload_is_found_in_both_harnesses():
    """The extraction must lock onto the real provisioner code, not drift."""
    for harness, path in HARNESSES.items():
        code = enrol_payload(path)
        assert "urllib.request.Request" in code, harness
        assert json.dumps({}) != code
        assert "PVEAPIToken=" in code, harness


def test_pool_rejects_post_like_real_pve(pve_server):
    """The mock must answer POST on /pools/{poolid} with PVE's own 501."""
    httpd, hits = pve_server
    base = f"http://127.0.0.1:{httpd.server_address[1]}"

    req = urllib.request.Request(
        base + POOL_PATH,
        data=b"vms=5900",
        method="POST",
    )
    with pytest.raises(urllib.error.HTTPError) as excinfo:
        urllib.request.urlopen(req, timeout=5)

    assert excinfo.value.code == 501
    body = excinfo.value.read().decode()
    assert body.startswith("501 Method 'POST /pools/ci-tests' not implemented")
    assert hits[-1][:2] == ("POST", POOL_PATH)


@pytest.mark.parametrize(
    "verb,path",
    [("PUT", "/api2/json/pools/other-pool"), ("GET", POOL_PATH)],
)
def test_off_contract_requests_fail_loud(pve_server, verb, path):
    """Anything outside the tested PUT-on-pool contract gets a plain 501."""
    httpd, hits = pve_server
    base = f"http://127.0.0.1:{httpd.server_address[1]}"

    req = urllib.request.Request(
        base + path,
        data=b"vms=5900" if verb in ("PUT", "POST") else None,
        method=verb,
    )
    with pytest.raises(urllib.error.HTTPError) as excinfo:
        urllib.request.urlopen(req, timeout=5)

    assert excinfo.value.code == 501
    assert hits[-1][:2] == (verb, path)
