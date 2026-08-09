# Runbook: Editing the Renovate Config

Validate and ship changes to `renovate.json5` (and triage the PRs it raises).

## Prerequisites

- Node.js **>= 24.11.0** (Renovate 44 hard-requires `^24.11.0`; node 22/24.0
  fails with "Unsupported node environment detected")
- npm registry access for the initial install (the sandbox blocks npm; install
  once and keep the copy)
- Gitea token **on the host** for full lookup tests; the sandbox has none and
  GitHub is rate-limited there (`skipReason: github-token-required`)

## 1. Validate + emulate locally (sandbox)

Install Renovate once, then dry-run against the repo with no platform/token:

```bash
mkdir -p /tmp/opencode/renodry && cd /tmp/opencode/renodry
npm init -y && npm install renovate          # e.g. 44.16.1

cd <repo>
RENOVATE_CONFIG_FILE=renovate.json5 \
  LOG_LEVEL=debug \
  /tmp/opencode/renodry/node_modules/.bin/renovate \
  --platform=local --dry-run=true
```

Notes:

- `--platform=local` reads the local git repo; no token, no remote needed.
  Do NOT pass a repo path argument — `repositories` is unsupported with
  `platform=local`.
- `LOG_LEVEL=debug` only when inspecting; default run prints little.
- Known warnings, not errors: `RE2 not usable` (falls back to RegExp),
  `Rate limit exceeded for api.github.com` / `github-token-required`
  (no hostRules in sandbox).

### What to check in the debug log

- Extraction: `"depName": "siderolabs/talos"` with
  `"currentValue": "v1.13.8"`, `"datasource": "github-tags"`,
  `"replaceString"` showing the exact matched span, and the correct
  `packageFile` (`infrastructure/units/public/talos/talos-cluster/terragrunt.hcl`).
- Kubernetes manager: `"currentValue": "1.36.2"` + `"extractVersion"` present.
- Guard rule merged: in the resolved config dump, the final
  `packageRules` entry has `"matchPackageNames": ["siderolabs/talos", ...]`,
  `"automerge": false`, `"prPriority": 10`,
  `"labels": ["renovate", "cluster-upgrade"]` — it must stay the LAST rule
  (or at least after the automerge rules) so `automerge: false` wins.

## 2. Ship

```bash
git add renovate.json5 docs/runbooks/renovate-config-edit.md
git commit        # scope: chore(renovate) for config, docs(runbooks) for this file
```

Normal PR flow (leela/fry). Do not merge the config PR and a
`cluster-upgrade` PR in the same batch if you want to review lookups first.

## 3. Triage Renovate PRs

- **`cluster-upgrade` label** (Talos/K8s): never automerged by design.
  Follow `docs/runbooks/talos-k8s-upgrade.md` — maintenance window, etcd
  snapshot, plan expectations.
- **`security` label**: OSV vulnerability alerts, `prPriority: 20`, not held
  by `minimumReleaseAge`. Merge promptly.
- **Everything else** (minor/patch, non-0.x): automerged by the last rules —
  nothing to do. Digests + lockfile maintenance also automerge.
- **`ignored: gitea-incompatible actions`**: `enabled: false`, an immortal PR
  here means the ignore rule stopped matching — re-check the action name.

## 4. If a config change misbehaves

- Re-run step 1 — the debug log shows the merged config, extraction and
  `skipReason`s; 90% of issues are regex/`managerFilePatterns` mismatches.
- Confirm the guard is still the last matching rule for
  `siderolabs/talos`/`kubernetes/kubernetes` (rule order is decisive for
  `automerge`).
- On the host, full validation with a real token:
  `RENOVATE_TOKEN=<gitea-token> npx renovate-config-validator`
