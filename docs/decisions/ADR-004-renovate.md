# ADR-004: Renovate over Dependabot for Automated Dependency Management

## Status

Accepted

## Context

The GitOps-managed Kubernetes stack (see [ADR-003](ADR-003-argocd.md)) accumulates independently versioned components across at least six ecosystems: Helm chart releases (ArgoCD `targetRevision` fields for cert-manager, Longhorn, [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack), [Loki](https://grafana.com/oss/loki/), CloudNativePG, Kyverno, Velero, and others), container image tags in Kubernetes manifests and Compose files, OpenTofu (see [ADR-002](ADR-002-opentofu-terragrunt.md)) provider versions, Terragrunt HCL references, Gitea Actions workflow dependencies, and tool versions pinned in CI steps.

Manual tracking doesn't scale past a handful of components and relies on discipline to maintain, which conflicts with the reproducibility goal established in [ADR-000](ADR-000-project-goals.md). Automated dependency management is the only viable approach.

[Dependabot](https://docs.github.com/en/code-security/dependabot) covers npm, pip, Go modules, GitHub Actions, and Docker. It has no Helm chart support, no OpenTofu/Terragrunt support, and no ArgoCD Application manifest support. For this stack, those are the primary update surfaces. Dependabot as the primary tool would leave the most important dependency categories unmanaged.

Renovate supports over 90 package managers, with first-class support for every ecosystem in this repo: the `argocd` manager for Application manifests, `helm-values` for image tags in values files, the `terraform` manager for `.tf` and `.hcl` files, native Docker Compose support, and regex-based custom managers for tool versions in CI scripts. It also opens a single Dependency Dashboard issue as a live inventory of all pending updates, rather than a flood of individual notifications.

The private Gitea instance is on a Local Area Network (LAN) and is not reachable from the public internet. [Mend](https://www.mend.io/)-hosted Renovate is not viable regardless of other preferences. Self-hosting is the only option.

## Decision

We will deploy Renovate as a scheduled Gitea Actions workflow running on a self-hosted runner. Updates are discovered nightly and opened as PRs against the private Gitea repository. Minor and patch updates are automerged when CI passes; major version bumps require manual review.

Core `renovate.json`:

```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": [":automergeMinor", "config:recommended"],
  "helm-values": {
    "fileMatch": ["kubernetes/.+/values\\.yaml$"]
  },
  "argocd": {
    "fileMatch": ["kubernetes/.+/application\\.yaml$"]
  },
  "terraform": {
    "fileMatch": ["infrastructure/.+\\.hcl$", "infrastructure/.+\\.tf$"]
  }
}
```

Gitea Actions workflow (`.gitea/workflows/renovate.yml`):

```yaml
on:
  schedule:
    - cron: '0 3 * * *'
  workflow_dispatch:
jobs:
  renovate:
    runs-on: self-hosted
    steps:
      - uses: actions/checkout@v4
      - name: Run Renovate
        uses: renovatebot/github-action@v40
        with:
          configurationFile: renovate.json
          token: ${{ secrets.RENOVATE_TOKEN }}
        env:
          RENOVATE_PLATFORM: gitea
          RENOVATE_ENDPOINT: https://gitea.yourdomain.internal
          RENOVATE_GIT_AUTHOR: Renovate Bot
```

Renovate is a [Node.js](https://nodejs.org/) CLI that runs to completion and exits. No persistent daemon, no in-cluster operator, no CRD.

Dependabot remains active on the public Codeberg (see [ADR-002](docs/decisions/ADR-002-opentofu-terragrunt.md))/GitHub mirror for passive CVE coverage via the [GitHub Advisory Database](https://github.com/advisories). It requires no configuration for public repos. The split is clean: Renovate handles proactive version bumps; Dependabot flags security issues reactively. They don't produce conflicting PRs because Renovate's updates typically pull in security fixes before a Dependabot security PR would be generated.

Renovate PRs are the trigger for the [n8n](https://n8n.io/) + [Ollama](https://ollama.com/) summarisation. Renovate's structured, consistent PR metadata (standardised titles, predictable diffs, machine-readable changelogs) gives the automation a reliable hook. An earlier version of this workflow auto-merged PRs after a positive LLM assessment; that was removed. A 7-8B local model has no access to CVE feeds and no knowledge of which transitive dependencies handle auth or crypto in this stack. Supply chain attacks targeting dependency update PRs are documented and active. The model's role is to give a faster path to an informed human decision, not to make the decision itself.

## Consequences

**Positive:**

- All Helm chart, container image, OpenTofu provider, and Gitea Actions version bumps arrive as PRs on a predictable schedule rather than being discovered ad-hoc
- The Dependency Dashboard issue in Gitea provides a single place to triage pending updates
- Minor and patch updates merge automatically after CI passes; major bumps require manual review
- Dependabot provides passive CVE coverage on the public mirror with no configuration overhead
- The Renovate PR webhook gives the n8n/Ollama summarisation workflow a structured, reliable trigger

**Negative:**

- During active upstream release periods, Renovate can open more PRs than is comfortable to review at once. Grouping rules and scheduled windows reduce volume, but some noise is inherent. The Dependency Dashboard mitigates this compared to per-notification email floods.
- Automerge depends on CI actually catching regressions. A CI suite with meaningful gaps means automerge will silently pass breaking changes. CI quality is a prerequisite for automerge to be safe.
- If the self-hosted runner is unavailable, Renovate jobs queue or fail. Missed runs delay updates but don't break anything. `workflow_dispatch` allows a manual trigger when a specific update is needed immediately.
