#!/usr/bin/env python3
"""Restore original Talos machine secrets into terraform state.

Used after `talos_machine_secrets` was regenerated (CA rotation) while the
cluster stayed on the original credentials, which locks out every talosconfig
with x509 errors. Reconstructs the secrets from:

  - the machine config of any node, dumped via a pre-rotation talosconfig
    (`talosctl -n <ip> get machineconfig v1alpha1 -o jsonpath='{.spec}'`)
  - a pre-rotation talosconfig (client CA/cert/key)

and writes them back into the terraform state file. See
docs/runbooks/talos-k8s-upgrade.md §7.
"""

import argparse
import hashlib
import json
import shutil

import yaml

CERT_MAPPING = (
    (("certs", "os", "cert"), ("machine", "ca", "crt")),
    (("certs", "os", "key"), ("machine", "ca", "key")),
    (("certs", "k8s", "cert"), ("cluster", "ca", "crt")),
    (("certs", "k8s", "key"), ("cluster", "ca", "key")),
    (("certs", "k8s_aggregator", "cert"), ("cluster", "aggregatorCA", "crt")),
    (("certs", "k8s_aggregator", "key"), ("cluster", "aggregatorCA", "key")),
    (("certs", "k8s_serviceaccount", "key"), ("cluster", "serviceAccount", "key")),
    (("certs", "etcd", "cert"), ("cluster", "etcd", "ca", "crt")),
    (("certs", "etcd", "key"), ("cluster", "etcd", "ca", "key")),
    (("cluster", "id"), ("cluster", "id")),
    (("cluster", "secret"), ("cluster", "secret")),
    (("secrets", "bootstrap_token"), ("cluster", "token")),
    (("trustdinfo", "token"), ("machine", "trustdinfo", "token")),
    (
        ("secrets", "secretbox_encryption_secret"),
        ("cluster", "secretboxEncryptionSecret"),
    ),
    (("secrets", "aescbc_encryption_secret"), ("cluster", "aescbcEncryptionSecret")),
)

CLIENT_MAPPING = (
    ("ca_certificate", "ca"),
    ("client_certificate", "crt"),
    ("client_key", "key"),
)


def get_path(mapping, key):
    cur = mapping
    for part in key:
        if part not in cur:
            return None
        cur = cur[part]
    return cur


def set_path(mapping, key, value):
    cur = mapping
    for part in key[:-1]:
        if part not in cur:
            cur[part] = {}
        cur = cur[part]
    cur[key[-1]] = value


def restore(state_path, machine_config_path, talosconfig_path):
    """Load state, replace machine secrets with the originals, write it back.

    Returns the (updated) machine_secrets attributes. Writes a
    ``<state>.pre-restore.bak`` copy before modifying the state file.
    """
    with open(machine_config_path) as f:
        machine_config = next(
            (
                d
                for d in yaml.safe_load_all(f)
                if isinstance(d, dict) and "machine" in d
            ),
            None,
        )
    if machine_config is None:
        raise ValueError(f"no machine config document found in {machine_config_path}")

    with open(talosconfig_path) as f:
        talosconfig = yaml.safe_load(f)
    try:
        context = talosconfig["contexts"][talosconfig["context"]]
    except KeyError as e:
        raise ValueError(
            f"malformed talosconfig: missing {e} in {talosconfig_path}"
        ) from e

    with open(state_path) as f:
        state = json.load(f)
    for resource in state["resources"]:
        if resource.get("type") == "talos_machine_secrets":
            break
    else:
        raise ValueError(f"no talos_machine_secrets resource found in {state_path}")
    attributes = resource["instances"][0]["attributes"]

    machine_secrets = attributes["machine_secrets"]
    for target, source in CERT_MAPPING:
        value = get_path(machine_config, source)
        if value is not None:
            set_path(machine_secrets, target, value)

    client_configuration = attributes["client_configuration"]
    for target, source in CLIENT_MAPPING:
        client_configuration[target] = context[source]

    shutil.copy2(state_path, state_path + ".pre-restore.bak")
    with open(state_path, "w") as f:
        json.dump(state, f, indent=2, sort_keys=True)

    return attributes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state", required=True, help="path to terraform.tfstate")
    parser.add_argument(
        "--machine-config",
        required=True,
        help="dumped node machine config (talosctl get machineconfig ... -o jsonpath='{.spec}')",
    )
    parser.add_argument(
        "--talosconfig", required=True, help="pre-rotation talosconfig path"
    )
    args = parser.parse_args()

    attributes = restore(args.state, args.machine_config, args.talosconfig)

    os_cert = attributes["machine_secrets"]["certs"]["os"]["cert"]
    os_key = attributes["machine_secrets"]["certs"]["os"]["key"]
    client = attributes["client_configuration"]
    print(f"talos_version: {attributes['talos_version']}")
    print(f"ca sizes: {len(os_cert)} {len(os_key)}")
    print(
        f"ca sha256: {hashlib.sha256(os_cert.encode()).hexdigest()[:16]} "
        f"{hashlib.sha256(os_key.encode()).hexdigest()[:16]}"
    )
    print(
        f"client_configuration sizes: {len(client['ca_certificate'])} "
        f"{len(client['client_certificate'])} {len(client['client_key'])}"
    )
    print(f"backup written to {args.state}.pre-restore.bak")


if __name__ == "__main__":  # pragma: no cover
    main()
