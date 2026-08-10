# Project Guidance: planet-express homelab

## Project Overview

A production-grade Kubernetes homelab on a single bare-metal host (Proxmox +
Talos + K8s + ArgoCD), fully IaC and reproducible. Every non-obvious choice has
an [ADR](docs/decisions/) explaining what was evaluated, what lost, and why.

- Repo is **python** (3.14): mostly tooling scripts, not an application
- Public mirror: internal network topology and private apps are stripped via
  `.gitattributes` `export-ignore` + `.gitea/workflows/mirror.yaml`. Never
  assume private content exists; never fetch or infer it
- SOPS-encrypted secrets in public paths are safe (ciphertext), never decrypt
  them

## Repo layout

| Path              | Contents                                           |
| ----------------- | -------------------------------------------------- |
| `ansible/`        | Ansible roles/playbooks (bootstrap, host config)   |
| `infrastructure/` | Talos cluster config, Terraform/Terragrunt units   |
| `kubernetes/`     | ArgoCD apps, Helm values, k8s manifests            |
| `docs/decisions/` | ADRs (numbered, `ADR-000-project-goals.md` starts) |
| `docs/runbooks/`  | Operational runbooks (e.g. `talos-k8s-upgrade.md`) |
| `scripts/`        | Python tooling (e.g. `link_adr.py`)                |
| `tests/`          | pytest suite for scripts                           |

## Tools and Commands

- **Python/uv**: `uv` manages deps; run scripts with `uv run python ...`
- **Tests**: `uv run pytest` (coverage on `scripts/`, branch coverage)
- **Lint**: `uv run ansible-lint`, `uv run pre-commit run --all-files`
- **Renovate**: `renovate.json5`: dependency updates are Renovate-managed
- **Secrets**: `.sops.yaml`: sops-encrypted files stay encrypted

## Conventions

- Every non-obvious decision gets an ADR; reference it from code/docs
- Runbooks must reflect actual state; known gaps documented as gaps
- Don't touch the `.gitattributes` filter list without checking the mirror
  workflow (`.gitea/workflows/mirror.yaml`)
- Never commit plaintext secrets; sops-encrypt in place

## Development Workflow

1. Read the relevant ADR/runbook before changing infra
2. Make changes
3. `uv run pre-commit run --all-files`
4. `uv run pytest`
5. Verify against live cluster where relevant (documented in runbooks)

## Testing Approach

- pytest in `tests/`, fixtures for setup
- Coverage targets `scripts/` with branch coverage (see `pyproject.toml`)
- Test scripts (`test_link_adr.py`) cover repo tooling, not infra itself
