# Runbook: Migrate OpenTofu State to the Garage S3 Backend

Moves every unit's state from the local files under
`terraform.tfstate.d/` into Garage S3 (`tofu-state` bucket), one unit at
a time, with verification after each unit. Decision context: [ADR-010](../decisions/ADR-010-garage.md).
Disaster-recovery framing: [ADR-015](../decisions/ADR-015-disaster-recovery.md).

## 1. Preconditions

- Garage LXC is up; S3 API answers on port 3900:
  ```bash
  aws --endpoint-url http://192.0.2.10:3900 --region garage s3 ls s3://tofu-state/
  ```
- The repo-local `terraform.tfstate.d/` tree matches what was last applied.
  Until the off-site backup solution deploys, these local files are the
  recovery source. Nothing in this runbook deletes them.
- `infrastructure/secrets.yaml` carries the backend credentials. Add them
  with sops if missing (values are the outputs of the `tofu-state` unit):
  ```bash
  cd infrastructure && sops secrets.yaml
  ```
  ```yaml
  garage:
      s3:
          access_key_id: <from tofu-state unit output>
          secret_access_key: <from tofu-state unit output>
  ```
  Read the values without printing them to shared terminals:
  ```bash
  cd infrastructure/units/public/garage/tofu-state
  terragrunt output access_key_id
  terragrunt output secret_key
  ```
  If the output names differ, list them with `terragrunt output` and pick
  the access-key id and its secret.
- `root.hcl` already contains the S3 `remote_state` block (merged before
  this runbook runs).

## 2. Confirm bucket keys match unit basenames

The backend keys state as `<unit-dir-basename>/terraform.tfstate` — the
same flat layout the bucket was seeded with. Verify before re-initializing
any unit:

```bash
aws --endpoint-url http://192.0.2.10:3900 --region garage \
  s3 ls s3://tofu-state/ --recursive | grep "terraform.tfstate$"
```

Every live unit needs exactly one object whose first path segment equals
its directory name (`garage-lxc/…`, `talos-vms/…`, …). A missing or oddly
named object: fix it now with `aws s3 cp`/`s3 mv` before §3. `*.backup`
and `*.bak` objects stay where they are; §5 removes them after
verification.

## 3. Cut over each unit

For every unit directory under `infrastructure/units/` (public and private):

```bash
cd infrastructure/units/public/<group>/<unit>
terragrunt init -reconfigure
```

`-reconfigure` adopts the new backend without offering to copy the stale
local copy over the freshly renamed remote object. Answer any backend-change
prompt with yes.

## 4. Verify before moving on

Per unit:

```bash
terragrunt state list      # same resources as before the cutover
terragrunt plan            # expect: No changes.
```

A failed plan to reach the backend means wrong endpoint, region, or
credentials — fix `secrets.yaml` or `root.hcl` before continuing. Do not
apply anything during this phase.

After all units pass individually, regenerate the stacks and plan once at
stack level (generated copies must resolve the same state keys):

```bash
cd infrastructure/stacks/public/<stack>
terragrunt stack run plan
```

## 5. Clean up stale objects

Only after EVERY unit plans clean:

```bash
aws --endpoint-url http://192.0.2.10:3900 --region garage s3 rm s3://tofu-state/buckets/ --recursive
aws --endpoint-url http://192.0.2.10:3900 --region garage s3 rm s3://tofu-state/keys/ --recursive
aws --endpoint-url http://192.0.2.10:3900 --region garage s3 rm s3://tofu-state --recursive \
  --exclude "*" \
  --include "*/terraform.tfstate.backup" \
  --include "*terraform.tfstate.pre-pin.bak" \
  --include "*terraform.tfstate.pre-restore.bak"
```

`buckets/` and `keys/` belonged to units merged into `tofu-state` earlier
(garage-lxc-setup runbook §4). Every deleted object still exists in the
host-local `terraform.tfstate.d/` tree.

## 6. Stale locks

Locking writes a `<key>.tflock` object next to each state. A crashed run
leaves it behind; the next run fails with a lock error. Clear it explicitly:

```bash
aws --endpoint-url http://192.0.2.10:3900 --region garage \
  s3 rm "s3://tofu-state/<unit-path>/terraform.tfstate.tflock"
```

Verify no unit is running before deleting a lockfile.

## 7. Interim exposure

Off-site backup of this bucket is planned but not deployed yet. Until it
lands, losing the Garage data volume means restoring state from the
host-local `terraform.tfstate.d/` tree: rebuild Garage, recreate/rename the
bucket objects to full-path keys (§2), then continue at §3. RPO equals the
age of those local files. Deploying the backup solution closes this gap.

## 8. Rollback

Revert the `remote_state` block in `root.hcl` to the local backend, then
`terragrunt init -reconfigure` per unit. The untouched local
`terraform.tfstate.d/` tree remains valid throughout.
