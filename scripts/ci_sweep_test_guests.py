#!/usr/bin/env python3
"""Sweep stale tftest-* guests from the Proxmox host.

Backstop for the native `tofu test` teardown of the live tier: any guest
whose name starts with tftest- or whose vmid sits in the reserved range
and that has been up longer than the cutoff gets stopped and destroyed.
The naming contract lives in docs/runbooks/infra-testing.md.

Reads only the ci-tests pool endpoint (`/pools/ci-tests`, its `members`
list); destructive delete calls go to the per-node endpoints. Auth uses a
PVE API token of the restricted ci-runner@pve user, whose ACL is limited
to the ci-tests pool, so the cluster-wide resources endpoint is denied.
Reading a pool still needs the `Pool.Audit` privilege on
`/pool/<pool>` (see docs/runbooks/infra-testing.md); missing that
privilege — or asking for a pool that does not exist — makes PVE answer
501, the same masking it uses for the denied cluster-wide route.
"""

from __future__ import annotations

import argparse
import json
import urllib.error
import urllib.parse
import urllib.request

RESERVED_VMID_FLOOR = 5900
TEST_PREFIX = "tftest-"


def normalize_base_url(url: str) -> str:
    """Validate an http(s) API base URL and guarantee a trailing slash.

    The caller concatenates its own resource path (e.g. /api2/json/pools/..)
    after this base, so a base that already ends in the API prefix must have
    that segment removed to avoid double-prefixing (which PVE answers 501).
    Only a terminal, whole-path api2/json segment is stripped; a nested one
    that still leaves a real resource path is left alone.
    """
    if not url.startswith(("http://", "https://")):
        raise ValueError(f"base URL must be http(s), got: {url}")
    parts = urllib.parse.urlsplit(url.rstrip("/"))
    if parts.path == "/api2/json":
        url = parts._replace(path="").geturl()
    return url + "/"


def auth_header(token_id: str, token_secret: str) -> str:
    """Build the Authorization header value for a PVE API token."""
    return f"PVEAPIToken={token_id}={token_secret}"


def _request(
    base_url: str,
    token_id: str,
    token_secret: str,
    path: str,
    method: str = "GET",
    timeout: float = 30.0,
) -> dict:
    req = urllib.request.Request(
        normalize_base_url(base_url) + path.lstrip("/"),
        method=method,
        headers={"Authorization": auth_header(token_id, token_secret)},
    )
    # Self-signed cert on the host; we authenticate by token, not TLS name.
    ctx = __import__("ssl")._create_unverified_context()
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
            payload = json.load(resp)
    except urllib.error.HTTPError as err:
        raise RuntimeError(
            f"PVE API returned HTTP {err.code} for {path} ({err.reason}); "
            "the token likely lacks the required privilege for this endpoint "
            "(pool reads need Pool.Audit on /pool/<pool>; PVE masks denied "
            "routes as 501) or the path does not exist"
        ) from err
    return payload.get("data", payload)


def fetch_guests(base_url: str, token_id: str, token_secret: str) -> list[dict]:
    data = _request(base_url, token_id, token_secret, "/api2/json/pools/ci-tests")
    return data.get("members", [])


def destroy_guest(base_url: str, token_id: str, token_secret: str, guest: dict) -> None:
    kind = "lxc" if guest["type"] == "lxc" else "qemu"
    _request(
        base_url,
        token_id,
        token_secret,
        f"/api2/json/nodes/{guest['node']}/{kind}/{guest['vmid']}",
        method="DELETE",
    )


def find_stale_guests(guests: list[dict], max_age_hours: float = 6.0) -> list[dict]:
    """Return guests that violate the test-namespace contract and are old.

    A guest qualifies when its name carries the tftest- prefix OR its vmid
    sits in the reserved range, AND its uptime reached max_age_hours.
    """
    cutoff_seconds = max_age_hours * 3600
    stale = []
    for guest in guests:
        in_namespace = (
            str(guest.get("name", "")).startswith(TEST_PREFIX)
            or int(guest.get("vmid", 0)) >= RESERVED_VMID_FLOOR
        )
        if not in_namespace:
            continue
        if int(guest.get("uptime", 0)) >= cutoff_seconds:
            stale.append(guest)
    return stale


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--token-id", required=True)
    parser.add_argument("--token-secret", required=True)
    parser.add_argument("--max-age-hours", type=float, default=6.0)
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="report what would be destroyed, destroy nothing",
    )
    args = parser.parse_args(argv)

    guests = fetch_guests(args.base_url, args.token_id, args.token_secret)
    stale = find_stale_guests(guests, max_age_hours=args.max_age_hours)

    for guest in stale:
        action = "WOULD-DESTROY" if args.dry_run else "DESTROY"
        print(
            json.dumps(
                {
                    action: {
                        "vmid": guest["vmid"],
                        "name": guest.get("name"),
                        "node": guest["node"],
                        "type": guest["type"],
                    }
                }
            )
        )
        if not args.dry_run:
            destroy_guest(args.base_url, args.token_id, args.token_secret, guest)

    if not stale:
        print("no stale test guests found")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
