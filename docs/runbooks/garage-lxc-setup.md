# Runbook: Garage LXC Setup and Bootstrap

Installs and operates the Garage S3 server that hosts the remote OpenTofu
state backend ([ADR-010](../decisions/ADR-010-garage.md)) and object storage ([ADR-015](../decisions/ADR-015-disaster-recovery.md)). Garage runs as a
Proxmox LXC guest, not inside Kubernetes (rulebook rule OBJ-01).

## Prerequisites

- Garage LXC provisioned by the `garage-lxc` unit
  (`infrastructure/units/public/proxmox/garage-lxc/`), running, reachable
  from the host as `root@<garage_lxc.ip>` with the `lxc_admin` key
- The Debian base image is ensured automatically by the `proxmox_base` role
  (`pveam` tag): it downloads the pinned template
  (`proxmox_base_pveam_template`) into the host's local storage if missing
- `infrastructure/secrets.yaml` has `network_config.garage_lxc.ip` and
  `.gw` plus `ssh_keys.lxc_admin` (used by the garage-lxc unit)
- Ansible collections installed on the host:
  `ansible-galaxy collection install -r ansible/requirements.yaml`
- All commands below run on the Proxmox host (zoidberg), which has the sops
  age key and the `lxc_admin_ed25519` SSH key in `~/.ssh/`

## 1. Create the encrypted host vars

The garage role reads its secrets from the host vars vault, mirroring the
`zoidberg` pattern (`ansible/inventory/host_vars/zoidberg/vault.sops.yaml`):

```bash
cd ansible
sops inventory/host_vars/garage-01/vault.sops.yaml
```

Required keys:

| Key                    | Value                                         |
| ---------------------- | --------------------------------------------- |
| `ansible_host`         | `192.0.2.10` (address part of the CIDR below) |
| `ansible_user`         | `root`                                        |
| `garage_rpc_secret`    | `openssl rand -hex 32`                        |
| `garage_admin_token`   | `openssl rand -hex 32`                        |
| `garage_metrics_token` | `openssl rand -hex 32`                        |

`ansible_host` must equal the address part of
`network_config.garage_lxc.ip`, which is stored as a CIDR
(e.g. `192.0.2.10/24`).

`ansible_host` and `ansible_user` are duplicated with the garage-lxc unit
inputs; keeping both encrypted here matches the existing zoidberg convention.

The admin token is the shared secret for the OpenTofu garage provider
(`garage/admin` API on port 3903). Record it in
`infrastructure/secrets.yaml` as:

```yaml
garage:
  admin_token: <same value>
```

## 2. Apply the guest setup

From `ansible/` on the host:

```bash
ansible-playbook playbooks/bootstrap.yaml
```

The play targets the `lxc` group, installs the pinned Garage 2.3.0 binary
(checksum-verified), writes `/etc/garage.toml` (the binary's default config
path; secrets from the vault), installs the `garage` systemd service, and
smoke-checks `garage node id`. To run only this step later:

```bash
ansible-playbook playbooks/bootstrap.yaml --limit garage-01 --tags garage
```

If the role runs before the host vars vault exists, sops decryption fails;
create the vault first (step 1).

## 3. Bootstrap the cluster layout

Done by the playbook: the garage role assigns the node role
(`garage layout assign -z dc1 <node id>`), applies the layout, and confirms
the cluster is healthy (`garage status`). The role is idempotent: once the
node has a role, re-runs skip assign and apply. The layout lives in
Garage's meta db, not in git.

Verify manually:

```bash
ssh -i ~/.ssh/lxc_admin_ed25519 root@192.0.2.10
garage status
```

`garage status` should show `Healthy` and a single node.

## 4. Provision the state bucket and access key

Requires Terragrunt with the Stacks feature (v0.78.0 or newer; the repo uses
explicit stacks defined in `infrastructure/stacks/public/*/terragrunt.stack.hcl`).
From `infrastructure/` on the host:

```bash
cd stacks/public/proxmox
terragrunt stack run apply
cd ../garage
terragrunt stack run apply
```

The garage stack (`infrastructure/stacks/public/garage/`) applies the single
`tofu-state` unit: bucket `tofu-state` plus access key `tofu-state` with
read/write on that bucket, using the `schwitzd/garage` provider and the
admin token from step 1.

Capture the generated access key, which is sensitive and shown only by
OpenTofu output:

```bash
cd stacks/public/garage
terragrunt stack output
```

### Troubleshooting: stale or broken generated stack

`stack run` fails with "folder that does not contain a `terragrunt.hcl` file"
pointing at a generated unit path: the `.terragrunt-stack` directory holds
stale units from an earlier generation (`stack generate` never deletes files
it no longer produces), or the CAS copy of the unit source failed on
provider-cache symlinks that escape the repository root. Regenerate from a
clean state:

```bash
cd stacks/public/proxmox   # or stacks/public/garage
terragrunt stack clean
find infrastructure/units -name .terragrunt-cache -type d -prune -exec rm -rf {} +
terragrunt stack run plan --no-cas
```

`--no-cas` skips the content-addressed copy; remove it once the source
directories no longer contain escaping symlinks.

Store `access_key_id` and `secret_access_key` in
`infrastructure/secrets.yaml` as `garage.state_access_key` (future units
that use the remote state backend read them from there).

### Migrating state from the former buckets/keys units

If this stack was applied while it still had separate `buckets` and `keys`
units, import their resources into the merged `tofu-state` unit instead of
recreating them — the access key secret is only visible at creation:

```bash
cd infrastructure
BUCKET_ID=$(cd units/public/garage/buckets && terragrunt output -raw bucket_id)
ACCESS_KEY_ID=$(cd units/public/garage/keys && terragrunt output -raw access_key_id)

cd units/public/garage/tofu-state
terragrunt init
terragrunt import 'garage_bucket.main[0]' "$BUCKET_ID"
terragrunt import 'garage_key.main[0]' "$ACCESS_KEY_ID"
terragrunt plan    # expect 1 to add (the binding), 0 to change, 0 to destroy
terragrunt apply
```

`garage_bucket_key` cannot be imported: the provider's importer is a plain
passthrough and drops the composite `<bucket_id>:<access_key_id>` id. Its
create path only re-asserts permissions on the existing binding, so the
one to-add in the plan converges without touching Garage. Afterwards remove
the old unit directories and their local state under
`terraform.tfstate.d/`, then regenerate the stack.

## 5. Verify S3 access

```bash
aws --endpoint-url http://192.0.2.10:3900 --region garage \
  s3 ls s3://tofu-state/
```

`ls` on an empty bucket lists nothing but must not error; wrong credentials
fail with `InvalidAccessKeyId` / `SignatureDoesNotMatch`. Region must match
`s3_region` from the config (`garage`).

## 6. What this runbook does not cover

- Migrating existing units to the remote Garage state backend: see
  [the migration runbook](tofu-state-migration.md); decision context in [ADR-010](../decisions/ADR-010-garage.md)
- The rclone snapshot schedule for Garage data (rulebook rule OBJ-02):
  destination and cadence are still to be defined (TODO in the rulebook)
- Garage upgrades: Renovate raises version-only PRs for `garage_version`
  (custom regex manager against git.deuxfleurs.fr tags). It cannot compute
  the artifact hash: add the matching `garage_checksum` manually in the same
  PR before merge — until then the checksum pin fails the next ansible run
  loudly. Verify the new binary with `--version` and `sha256sum` first
  (releases are published on garagehq.deuxfleurs.fr / git.deuxfleurs.fr,
  not GitHub), then re-run
  `ansible-playbook playbooks/bootstrap.yaml --limit garage-01 --tags garage`
