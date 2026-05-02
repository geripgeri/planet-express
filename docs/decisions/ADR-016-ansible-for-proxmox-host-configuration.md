# ADR-016: Ansible for Proxmox Host Configuration

## Status

Active

## Context

OpenTofu (see [ADR-002](ADR-002-opentofu-terragrunt.md)) manages everything with an API: LXC containers, VMs, DNS, object storage, Kubernetes workloads. Proxmox itself sits below that layer. Repository sources, package state, sysctl tuning, SSH hardening, the fan curve, and the pve-exporter service feeding Grafana (see [ADR-011](ADR-011-observability.md)) are host-level concerns that were set up by hand, via SSH, using community scripts and one-off edits that were never written down.

That accumulation of undocumented manual steps is exactly the failure mode [ADR-000](ADR-000-project-goals.md) is designed to prevent. The IaC reproducibility goal is not satisfied if the Proxmox host is a snowflake that can only be reconstructed by reading bash history.

The tool managing host configuration needs to satisfy four requirements:

- **Idempotent.** Safe to re-run on a live host with VMs running. It enforces desired state without requiring awareness of intermediate states.
- **Agentless.** Adding a persistent agent process to the hypervisor introduces an attack surface and a service dependency. The tool should connect over SSH and leave nothing behind.
- **YAML-native.** Every other configuration layer in this project is YAML: Kubernetes manifests, Helm values, OpenTofu variables, Gitea Actions workflows. A different DSL has real cognitive cost in a solo project.
- **Testable in CI.** Linting and syntax validation must run on Gitea Actions without a live host.

Bash scripts were considered and rejected: they have no native idempotency, no inventory model, no secrets integration, and running ad-hoc shell on a live hypervisor is dangerous in a way structured task execution is not. [Chef](https://www.chef.io) and [Puppet](https://www.puppet.com) both require a persistent agent and a management server, and neither is YAML-native. [SaltStack](https://saltproject.io) supports agentless mode via [`salt-ssh`](https://docs.saltproject.io/en/latest/topics/ssh/), but it's a second-class citizen in that ecosystem and has weaker community signal than Ansible. OpenTofu provisioners are explicitly documented as a last resort: they run only at resource creation time, produce no diff, and are not idempotent by design.

[Ansible](https://www.ansible.com) is the natural fit: agentless over SSH, idempotent by module design, YAML-native, and has the largest community footprint of any agentless configuration management tool.

**What Ansible owns:**

- Proxmox apt repository configuration
- Package state beyond the base install
- `sysctl` tuning for Kubernetes networking and disk scheduling
- SSH hardening
- Fan control: the curve config file and the `fancontrol` systemd service
- pve-exporter: credentials, the Prometheus exporter binary, and its systemd service
- Host-level scripts that survived the bash history audit

**What Ansible does not own:**

- Initial Proxmox installation: would require PXE/kickstart infrastructure that costs more to build than it saves
- Proxmox cluster join sequence: same reasoning
- VM and LXC state: OpenTofu owns this

The boundary is: Ansible owns the OS layer; OpenTofu owns the resource layer. When Ansible manages a file that OpenTofu also touches, that is a design error.

## Decision

I will use [Ansible](https://www.ansible.com) to manage Proxmox host configuration.

The implementation lives under `ansible/` with one role per concern: `proxmox_base`, `fan_control`, `pve_exporter`, `custom_scripts`. The main `bootstrap.yaml` playbook calls all roles in order and is safe to re-run at any time. A companion `verify.yaml` playbook checks desired state without making changes and runs in CI on every PR touching `ansible/`. Secrets in `ansible/host_vars/proxmox.yaml` are encrypted with SOPS (see [ADR-009](ADR-009-sops.md)) and age, consistent with the rest of the repository.

## Consequences

- Proxmox host configuration is committed to git, linted by [`ansible-lint`](https://ansible.readthedocs.io/projects/lint/) in Gitea Actions on every PR, and reproducible from a documented starting point
- Any change to host state goes through `ansible/` rather than directly via SSH
- Fan control, pve-exporter, and host hardening are managed as code with the same discipline as the Kubernetes and OpenTofu layers
- The OS/resource boundary between Ansible and OpenTofu must be respected as new host-level concerns are added; drift here creates confusion about which tool is authoritative
- Host state that cannot be made safely idempotent is documented in `docs/runbooks/proxmox-rebuild.md` rather than forced into playbooks or silently omitted; together, the runbook and `bootstrap.yaml` answer the question of what to do if the bare metal dies tonight
- Ansible does not reconstruct the Proxmox OS from scratch; a physical install from ISO is still required before Ansible's scope begins
