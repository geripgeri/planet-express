import json
import sys

import pytest
import yaml

from scripts.restore_machine_secrets import main, restore


@pytest.fixture
def state_file(tmp_path):
    state = {
        "resources": [
            secrets_resource(
                {
                    "id": "machine_secrets",
                    "talos_version": "v1.13.8",
                    "client_configuration": {
                        "ca_certificate": "OLD-CA",
                        "client_certificate": "OLD-CERT",
                        "client_key": "OLD-KEY",
                    },
                    "machine_secrets": {
                        "certs": {
                            "os": {"cert": "OLD-OS-CERT", "key": "OLD-OS-KEY"},
                            "k8s": {
                                "cert": "OLD-K8S-CERT",
                                "key": "OLD-K8S-KEY",
                            },
                            "k8s_aggregator": {
                                "cert": "OLD-AGG-CERT",
                                "key": "OLD-AGG-KEY",
                            },
                            "k8s_serviceaccount": {"key": "OLD-SA-KEY"},
                            "etcd": {
                                "cert": "OLD-ETCD-CERT",
                                "key": "OLD-ETCD-KEY",
                            },
                        },
                        "cluster": {"id": "OLD-ID", "secret": "OLD-SECRET"},
                        "secrets": {"bootstrap_token": "OLD-TOKEN"},
                        "trustdinfo": {"token": "OLD-TRUSTD"},
                    },
                }
            )
        ]
    }
    path = tmp_path / "terraform.tfstate"
    path.write_text(json.dumps(state))
    return path


@pytest.fixture
def machine_config(tmp_path):
    config = {
        "version": "v1alpha1",
        "machine": {
            "ca": {"crt": "CA-CRT", "key": "CA-KEY"},
            "trustdinfo": {"token": "TRUSTD-TOKEN"},
        },
        "cluster": {
            "id": "CLUSTER-ID",
            "secret": "CLUSTER-SECRET",
            "token": "BOOTSTRAP-TOKEN",
            "ca": {"crt": "K8S-CRT", "key": "K8S-KEY"},
            "aggregatorCA": {"crt": "AGG-CRT", "key": "AGG-KEY"},
            "serviceAccount": {"key": "SA-KEY"},
            "etcd": {"ca": {"crt": "ETCD-CRT", "key": "ETCD-KEY"}},
        },
    }
    path = tmp_path / "machine-config.yaml"
    path.write_text(yaml.safe_dump(config))
    return path


@pytest.fixture
def talosconfig(tmp_path):
    config = {
        "context": "talos-cluster-01",
        "contexts": {
            "talos-cluster-01": {
                "endpoints": ["192.168.10.30"],
                "ca": "TC-CA",
                "crt": "TC-CRT",
                "key": "TC-KEY",
            }
        },
    }
    path = tmp_path / "talosconfig"
    path.write_text(yaml.safe_dump(config))
    return path


def secrets_resource(attributes):
    return {
        "type": "talos_machine_secrets",
        "name": "this",
        "instances": [{"attributes": attributes}],
    }


def load_attrs(state_path):
    with open(state_path) as f:
        state = json.load(f)
    resource = next(
        r for r in state["resources"] if r.get("type") == "talos_machine_secrets"
    )
    return resource["instances"][0]["attributes"]


def test_restore_full(state_file, machine_config, talosconfig):
    """All cert fields, cluster id/secret, tokens, and client config are restored."""
    restore(str(state_file), str(machine_config), str(talosconfig))

    attrs = load_attrs(state_file)
    ms = attrs["machine_secrets"]
    assert ms["certs"]["os"]["cert"] == "CA-CRT"
    assert ms["certs"]["os"]["key"] == "CA-KEY"
    assert ms["certs"]["k8s"]["cert"] == "K8S-CRT"
    assert ms["certs"]["k8s_aggregator"]["cert"] == "AGG-CRT"
    assert ms["certs"]["k8s_serviceaccount"]["key"] == "SA-KEY"
    assert ms["certs"]["etcd"]["key"] == "ETCD-KEY"
    assert ms["cluster"]["id"] == "CLUSTER-ID"
    assert ms["cluster"]["secret"] == "CLUSTER-SECRET"
    assert ms["secrets"]["bootstrap_token"] == "BOOTSTRAP-TOKEN"
    assert ms["trustdinfo"]["token"] == "TRUSTD-TOKEN"

    client = attrs["client_configuration"]
    assert client["ca_certificate"] == "TC-CA"
    assert client["client_certificate"] == "TC-CRT"
    assert client["client_key"] == "TC-KEY"

    assert attrs["talos_version"] == "v1.13.8"


def test_restore_missing_optional_fields(state_file, machine_config, talosconfig):
    """
    Nodes on current Talos no longer carry trustdinfo/encryption secrets; those
    state values must be left untouched instead of erroring.
    """
    with open(machine_config) as f:
        config = yaml.safe_load(f)
    del config["machine"]["trustdinfo"]
    machine_config.write_text(yaml.safe_dump(config))

    restore(str(state_file), str(machine_config), str(talosconfig))

    attrs = load_attrs(state_file)
    assert attrs["machine_secrets"]["trustdinfo"]["token"] == "OLD-TRUSTD"
    assert attrs["machine_secrets"]["certs"]["os"]["cert"] == "CA-CRT"


def test_restore_no_config_document(tmp_path, state_file, talosconfig):
    """A machine config file without a config document is rejected."""
    empty = tmp_path / "empty.yaml"
    empty.write_text("---\njust: metadata\n")

    with pytest.raises(ValueError, match="no machine config document"):
        restore(str(state_file), str(empty), str(talosconfig))


def test_restore_no_secrets_resource(tmp_path, talosconfig):
    """State without a talos_machine_secrets resource is rejected."""
    state_path = tmp_path / "state.json"
    state_path.write_text(json.dumps({"resources": []}))
    config = tmp_path / "mc.yaml"
    config.write_text(
        yaml.safe_dump({"machine": {"ca": {"crt": "X", "key": "Y"}}, "cluster": {}})
    )

    with pytest.raises(ValueError, match="no talos_machine_secrets resource"):
        restore(str(state_path), str(config), str(talosconfig))


def test_restore_skips_other_resources(tmp_path, talosconfig):
    """Non-matching resources earlier in the state are skipped."""
    state_path = tmp_path / "state.json"
    state_path.write_text(
        json.dumps(
            {
                "resources": [
                    {
                        "type": "aws_instance",
                        "instances": [{"attributes": {"id": "x"}}],
                    },
                    secrets_resource(
                        {
                            "talos_version": "v1.12.4",
                            "client_configuration": {},
                            "machine_secrets": {
                                "certs": {"os": {"cert": "OLD", "key": "OLD"}},
                                "cluster": {},
                                "secrets": {},
                            },
                        }
                    ),
                ]
            }
        )
    )
    config = tmp_path / "mc.yaml"
    config.write_text(
        yaml.safe_dump(
            {"machine": {"ca": {"crt": "CA-CRT", "key": "CA-KEY"}}, "cluster": {}}
        )
    )

    restore(str(state_path), str(config), str(talosconfig))

    assert load_attrs(state_path)["machine_secrets"]["certs"]["os"]["cert"] == "CA-CRT"


def test_main(monkeypatch, capsys, state_file, machine_config, talosconfig):
    """CLI entry point restores and reports sizes/checksums of the result."""
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "restore_machine_secrets.py",
            "--state",
            str(state_file),
            "--machine-config",
            str(machine_config),
            "--talosconfig",
            str(talosconfig),
        ],
    )

    main()

    out = capsys.readouterr().out
    assert "talos_version: v1.13.8" in out
    assert "ca sizes:" in out
    assert "ca sha256:" in out
    assert "client_configuration sizes:" in out
    assert f"backup written to {state_file}.pre-restore.bak" in out
    assert state_file.with_name(state_file.name + ".pre-restore.bak").exists()


def test_main_entrypoint(tmp_path, state_file, machine_config, talosconfig):
    """Script run as __main__ (module guard) reaches main()."""
    import subprocess
    from pathlib import Path

    from scripts import restore_machine_secrets

    result = subprocess.run(
        [
            sys.executable,
            str(Path(restore_machine_secrets.__file__)),
            "--state",
            str(state_file),
            "--machine-config",
            str(machine_config),
            "--talosconfig",
            str(talosconfig),
        ],
        capture_output=True,
        text=True,
        check=True,
    )

    assert "backup written to" in result.stdout
