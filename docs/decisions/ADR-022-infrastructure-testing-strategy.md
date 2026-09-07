# ADR-022: Infrastructure Testing Strategy — Layered Pyramid with Native OpenTofu Tests

## Status

Accepted (2026-08-23). Supersedes the tooling choice in
[ADR-000](ADR-000-project-goals.md) for the integration tier: [ADR-000](ADR-000-project-goals.md) specified
Terratest Go tests; this ADR replaces them with native OpenTofu tests.
The two-tier concept of [ADR-000](ADR-000-project-goals.md) (static on hosted runners, live against
catalogs only) remains valid and is preserved here.

## Context

Infrastructure code needs automated testing, and the testing budget must
respect three hard facts of this homelab:

- One bare-metal Proxmox host (zoidberg, 32GB) already runs the Talos
  cluster; live tests compete with production guests for headroom.
- Production OpenTofu state lives in the Garage S3 backend on the same
  host; test runs must never touch it.
- The repo is Python-first; adding a Go toolchain has real maintenance
  cost.

Since [ADR-000](ADR-000-project-goals.md) was written, OpenTofu gained a mature native test framework
(tofu test, GA since 1.6; mock_provider since 1.7). Industry practice in
2025–2026 (env0, Scalr, Gruntwork commentary) converged on treating
native tests and Terratest not as rivals but as pyramid layers: native
HCL tests for unit and simple integration, Go-based Terratest only where
multi-step orchestration genuinely demands it.

The catalog/unit/stack split from [ADR-002](ADR-002-opentofu-terragrunt.md) makes the layering cheap:
catalogs carry no backend configuration, so direct `tofu test` runs use
local throwaway state and physically cannot touch production state.

## Decision

Four layers, ordered cheapest-first:

| Layer     | Tool                                                | Runner      | Trigger                  |
| --------- | --------------------------------------------------- | ----------- | ------------------------ |
| L1 static | tofu fmt/validate, tflint, trivy (catalogs)         | hosted      | every infra PR/push      |
| L2 unit   | tofu test with mock_provider                        | hosted      | every infra PR/push      |
| L3 plan   | terragrunt stack run plan                           | self-hosted | infra PRs                |
| L4 live   | tofu test command=apply, one tiny LXC + one tiny VM | self-hosted | merges to main + nightly |

Guardrails: reserved vmid range 5900–5999, tftest- name prefix, dedicated
ci-runner@pve API user scoped to a ci-tests pool, Gitea concurrency group
serializing live runs, nightly orphan sweep (scripts/ci_sweep_test_guests.py).

Terratest remains the escape hatch for future multi-step suites (for
example a mini-Talos bootstrap drill). Such a suite reuses the same pool,
vmid and secrets contracts; existing HCL tests are not converted.

## Consequences

- Positive: no Go toolchain; teardown semantics guaranteed by the test
  framework; production guests protected by three independent guardrails
  (ACL scope + naming contract + sweep backstop); provider upgrades
  exercised by L4 before production units consume them.
- Negative: telmate/proxmox flakiness surfaces as noisy nightly runs;
  L3/L4 need a runner with routes to the Proxmox API and Garage; the LAN
  runner serves that role (registered under the `ubuntu-latest` label,
  see docs/runbooks/infra-testing.md).
- Neutral: [ADR-000](ADR-000-project-goals.md) readers must follow this ADR for tooling questions.
