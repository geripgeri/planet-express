# Runbook: Infrastructure Testing

How to run the four test tiers from [ADR-022](../decisions/ADR-022-infrastructure-testing-strategy.md) locally and in CI, and the
resource-naming contract that keeps test guests away from production.

## Tier overview

| Tier      | What                                             | Command                                                               | Where         |
| --------- | ------------------------------------------------ | --------------------------------------------------------------------- | ------------- |
| L1 static | fmt, validate, tflint, trivy over catalogs       | push/PR (automatic) or commands below                                 | anywhere      |
| L2 unit   | mocked catalog tests, no credentials             | `tofu -chdir=infrastructure/catalogs/public/<cat> test`               | anywhere      |
| L3 plan   | real-config plans vs live state                  | `terragrunt stack run plan` in `infrastructure/stacks/public/<stack>` | host/home net |
| L4 live   | boots tiny LXC (5900) + VM (5901), auto-teardown | `tofu -chdir=infrastructure/tests/live/<cat> test`                    | host/home net |

## Naming contract (hard rule)

- Test guests: vmid 5900–5999 ONLY, name MUST start with `tftest-`.
- Production guests live at vmid 110 and 500–503. Anything else you
  create by hand inside 5900–5999 WILL be destroyed by the nightly sweep
  once older than 6 hours.
- The `ci-tests` Proxmox resource pool owns the range; the
  `ci-runner@pve` API user holds ACL grants limited to it.

## Running tiers locally (from the host or any machine with routes)

L2 (safe everywhere):

```
tofu -chdir=infrastructure/catalogs/public/lxc init -backend=false
tofu -chdir=infrastructure/catalogs/public/lxc test
tofu -chdir=infrastructure/catalogs/public/proxmox-vm init -backend=false
tofu -chdir=infrastructure/catalogs/public/proxmox-vm test
```

L3 (reads/writes nothing; takes the Garage lockfile briefly):

```
cd infrastructure/stacks/public/proxmox && terragrunt stack run plan
cd ../garage && terragrunt stack run plan
```

Stack-run gotcha: do NOT add a `dependency` block between two units in
the same stack. `stack run` resolves it by executing `tofu output -json`
in the dependency unit's generated workdir, but that unit is never inited
in the run phase, so the executor fails with "Required plugins are not
installed" and the consuming unit then fails with "There is no variable
named `dependency`". `mock_outputs` do not help. If the units share
topology, read the shared base config instead: e.g. `talos-cluster` reads
IPs and VMIDs straight from `talos/base.hcl`, which is the same
`cidrhost` formula `talos-vms` computes (see
`infrastructure/units/public/talos/talos-cluster/terragrunt.hcl`). Same
class of bug as the `include.<label>.locals` null trap — prefer
`read_terragrunt_config`.

L4 (creates and destroys real guests; ~1.5GB peak RAM; never run two at
once, and not while another Terragrunt run holds the stack lock):

```
export TF_VAR_pm_api_url=... TF_VAR_pm_api_token_id=... \
       TF_VAR_pm_api_token_secret=... TF_VAR_pm_target_node=zoidberg
tofu -chdir=infrastructure/tests/live/lxc init
tofu -chdir=infrastructure/tests/live/lxc test
tofu -chdir=infrastructure/tests/live/vm init
tofu -chdir=infrastructure/tests/live/vm test
```

Sweep (dry run first):

```
python3 scripts/ci_sweep_test_guests.py --base-url "$PROXMOX_API_URL" \
  --token-id "$PROXMOX_API_TOKEN_ID" --token-secret "$PROXMOX_API_TOKEN" \
  --dry-run
# drop --dry-run to actually destroy
```

The sweep reads `/pools/ci-tests`, whose `members` list carries the same
vmid/name/uptime/node/type shape as `/cluster/resources`. Two PVE details
are easy to misread:

- `/cluster/resources` is a restricted route: for an account without the
  required cluster-wide audit privileges PVE answers `501 Method 'GET ...' not implemented`, not 403 — a deliberate mask so denied access
  looks like a non-existent endpoint.
- Reading a single pool (`GET /pools/{poolid}`) is NOT granted by pool
  membership alone. It needs the `Pool.Audit` privilege on
  `/pool/ci-tests` (`Pool.Allocate` only covers creating and editing
  pools, not reading them). A denied privilege and a pool id that does
  not exist both fail the read; the first live sweep run hit the
  second: `ci-tests` did not exist (only `ci-runner`, empty) and PVE
  answered 501. Create the pool (`pveum pool create ci-tests`), grant
  `Pool.Audit` to the ci-runner role (step 3 below), assign the
  live-tier guests into the pool, then re-run `--dry-run` before
  relying on the sweep.

## One-time self-hosted runner setup checklist

1. Register a Gitea runner on a machine with routes to the Proxmox API
   (:8006) and Garage (:3900). The LAN runner is registered with the
   `ubuntu-latest` label (the default for `act_runner`); workflows target
   it with `runs-on: ubuntu-latest`.
2. The workflows bootstrap their own toolchain: OpenTofu via the
   `opentofu/setup-opentofu` action, terragrunt and sops via download
   steps in `.gitea/workflows/tofu-plan.yaml`. The runner host itself
   only needs `python3` plus outbound routes to Gitea, GitHub, the
   Proxmox API (:8006) and Garage (:3900).
3. Proxmox: create user `ci-runner@pve`, role limited to VM/LXC
   create/start/stop/destroy on pool `ci-tests`, issue an API token.
   Create the pool with `pveum pool create ci-tests` — the sweep reads
   its `members` list, and a missing pool id makes PVE answer 501. Add
   the `Pool.Audit` privilege on `/pool/ci-tests` to that role
   (`Pool.Allocate` is only for pool create/edit/delete, so it does not
   help the read). Assign the live-tier guests into the pool so the
   sweep can see them.
4. Age: generate a dedicated keypair; add its public key to the
   recipients in `.sops.yaml` creation rules; re-encrypt
   `infrastructure/secrets.yaml` (sops rotate -i -r).
5. Gitea repo secrets: `SOPS_AGE_KEY` (private key), `PROXMOX_API_URL`,
   `PROXMOX_API_TOKEN_ID`, `PROXMOX_API_TOKEN`.

## Current gaps

- The VM live harness boots hardware without an installer ISO; it proves
  catalog wiring, not guest OS health. Guest-agent-based assertions are a
  possible follow-up.
- The live VM fixture pins a static MAC (`bc:24:11:2a:3b:4c`); a leaked
  vmid-5901 guest can ARP-conflict until the sweep removes it (≤6h
  window).
- `lxc_ostemplate` default in the live wrappers duplicates the
  Renovate-managed pin in ansible/roles/proxmox_base/defaults/main.yaml;
  the wrapper default previously diverged from that pin (12.7 vs 12.12,
  fixed in this commit). Update them together (Renovate does not know
  about the wrapper).
- The argocd stack (infrastructure/stacks/public/argocd) stays outside
  the L3 plan gate until the runner holds its kubeconfig and sops age
  inputs; PRs touching that stack therefore get no plan coverage today.

## Verification history

| Date       | Check                                                  | Result                                                                                                                |
| ---------- | ------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------- |
| 2026-09-06 | Sweep dry-run live (first run)                         | failed 501: pool `ci-tests` did not exist (only `ci-runner`, empty); create pool, grant `Pool.Audit`, retry           |
| 2026-09-07 | Sweep dry-run live (base URL with `/api2/json` suffix) | pass — `no stale test guests found`; the trailing `/api2/json` segment in `PROXMOX_API_URL` is stripped by the script |
| 2026-09-07 | L1/L2 green in CI                                      | pass — static/unit tiers on the LAN runner; static tflint `-c` config bug fixed in this PR (re-run after merge)       |
| 2026-09-07 | L4 dispatch creates+destroys both guests               | pass                                                                                                                  |
| 2026-09-07 | Sweep destroys planted tftest-orphan (5999)            | pass                                                                                                                  |

Update this table as tiers go live. Known gaps above must stay honest.
