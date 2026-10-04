# ADR-002: OpenTofu + Terragrunt for Infrastructure Provisioning

## Status

Active

## Context

Proxmox VMs and LXCs, the Talos cluster (see [ADR-001](ADR-001-kubernetes.md)), [Authentik](https://goauthentik.io) identity, and Garage object storage (see [ADR-010](ADR-010-garage.md)) all need to be managed as code, and the reproducibility goal sets that requirement (see [ADR-000](ADR-000-project-goals.md)). Two questions follow: which tool provisions, and how is it structured to stay manageable as the stack grows.

**Why not Terraform**: HashiCorp [relicensed](https://www.hashicorp.com/en/blog/hashicorp-adopts-business-source-license) [Terraform](https://www.terraform.io) from [Mozilla Public License (MPL)-2.0](https://www.mozilla.org/en-US/MPL/2.0/) to the [Business Source License (BSL) 1.1](https://mariadb.com/bsl11/) in August 2023. BSL is not open source, and its terms can change unilaterally by the licensor (now IBM, after the 2024 acquisition). That conflicts with the open source values behind every tool choice here, and adds governance risk that CNCF-hosted projects do not have.

**Why structure matters**: without Terragrunt, backend config, provider version constraints, and shared variables must be duplicated across every OpenTofu unit, or consolidated into one root module holding all resources in a single state file. The stack spans multiple providers and dozens of resources, so a flat layout becomes unmanageable: a bug in one resource blocks unrelated changes, and there is no natural boundary for a public/private split.

## Decision

I will use [OpenTofu](https://opentofu.org) for resource provisioning and [Terragrunt](https://terragrunt.gruntwork.io) for structure, following the [catalog](https://docs.terragrunt.com/features/catalog/)/[stack](https://docs.terragrunt.com/features/stacks/)/[unit](https://docs.terragrunt.com/features/units/) pattern.

**OpenTofu** is the CNCF-backed MPL-2.0 fork of Terraform, created after the BSL relicensing. It is drop-in compatible with Terraform HashiCorp Configuration Language (HCL), providers, and state files. Every provider in this stack ([telmate/proxmox](https://github.com/Telmate/terraform-provider-proxmox), [gmichels/adguard](https://github.com/gmichels/terraform-provider-adguard), [goauthentik/authentik](https://github.com/goauthentik/terraform-provider-authentik), [Kubernetes](https://registry.terraform.io/providers/hashicorp/kubernetes/latest), [Helm](https://registry.terraform.io/providers/hashicorp/helm/latest)) works unchanged. CNCF governance prevents unilateral license changes.

One difference from Terraform: DynamoDB-based state locking is deprecated in OpenTofu. The replacement is `use_lockfile = true`, which writes a `.tflock` object alongside the state file in S3. Garage (see [ADR-010](ADR-010-garage.md)) supports the required `PutObject` and `DeleteObject` operations natively.

**Terragrunt** provides a `root.hcl` defining backend config, provider constraints, and shared inputs once. Every unit inherits by reference, so updating the Garage endpoint is a one-line change in one file.

The three-layer structure:

- **Catalog modules** (`infrastructure/catalogs/`): pure HCL with resource definitions, variables, and outputs. A catalog defines what a Proxmox LXC looks like as code, not which one. Safe to publish publicly, visible in full on the GitHub mirror.
- **Units** (`infrastructure/units/`): each unit is a `terragrunt.hcl` instantiating one catalog module with live values. One unit = one state file, so changing the NFS LXC config cannot touch the Garage LXC state.
- **Stacks** (`infrastructure/stacks/`): a `terragrunt.stack.hcl` groups related units, declares dependency order, and wires outputs between units. The Garage stack applies the LXC before buckets, buckets before keys, and passes the LXC's IP downstream without scattering `dependency` blocks.

The public/private boundary follows this structure: `catalogs/public/` and `units/public/` are mirrored to GitHub; `catalogs/private/` and `units/private/` are excluded via `.gitattributes` `export-ignore`. Patterns are visible, live configuration is not.

## Alternatives Considered

**Raw OpenTofu without Terragrunt**: viable for small stacks, but backend config and provider constraints must be duplicated across every directory, or a single root module puts everything in one plan. No natural boundary for the public/private split. Rejected before the first resource was provisioned.

**Terraform (accepting BSL)**: OpenTofu is a drop-in replacement with no migration cost. Given the project's consistent preference for open source under CNCF governance, there is no reason to accept BSL's constraints or IBM's governance risk.

**[Pulumi](https://www.pulumi.com)**: uses TypeScript/Python/Go instead of HCL, which helps with complex conditionals and unit testing. Two blockers: the [telmate/proxmox](https://github.com/Telmate/terraform-provider-proxmox) provider has no mature Pulumi wrapper, so bridge code or reduced coverage is required; and HCL is the industry standard for IaC, making OpenTofu fluency a more direct portfolio signal. [Terratest](https://terratest.gruntwork.io) covers integration testing at the level that matters.

**Ansible for everything**: can provision Proxmox resources, but has no native state management, no plan/apply semantics, and no drift detection. It is the right tool for host configuration (packages, sysctl, services), not resource provisioning. See [ADR-016](ADR-016-ansible-for-proxmox-host-configuration.md) for the Ansible boundary.

**[CDK for Terraform](https://developer.hashicorp.com/terraform/cdktf) / [CDK8s](https://cdk8s.io/)**: generates HCL from general-purpose code, but the output is not human-readable or reviewable in a pull request, which conflicts with a legible portfolio. CDK8s was dropped for the same reason.

## Consequences

- All infrastructure resources with provider support are managed as OpenTofu code via Terragrunt; no manual clicks in the Proxmox UI for routine provisioning
- Adding an LXC or application is `terragrunt scaffold` plus live values, not copying a directory
- State lives in Garage S3 from the first resource; local state is never canonical and never committed to git
- `use_lockfile = true` replaces DynamoDB locking, so no external locking infrastructure is needed
- The GitHub and Codeberg mirrors expose all catalog modules in full, showing the patterns, while private units are excluded
- Garage does not support bucket versioning; periodic rclone snapshots of the Garage data directory compensate (documented in the Garage runbook)
- [Terratest](https://terratest.gruntwork.io) integration tests run against catalog modules and the real Proxmox API, not production units: a test provisions an isolated resource, asserts on it, and tears it down
