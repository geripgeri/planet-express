# Install Toolchain

This document is the single source of truth for installing and verifying the toolchain needed to work on this repo. It is kept up to date whenever the tooling changes or an issue surfaces (enforced in AGENTS.md).

## Tools

| Tool       | Purpose                    | Install method        |
| ---------- | -------------------------- | --------------------- |
| uv         | Python package manager     | dedicated installer   |
| pre-commit | Git hooks (local CI gates) | `uv sync` dependency  |
| tfswitch   | OpenTofu version switch    | install script / brew |
| tgswitch   | Terragrunt version switch  | install script / brew |
| OpenTofu   | IaC provisioning           | `tfswitch`            |
| Terragrunt | IaC orchestration          | `tgswitch`            |
| sops       | Secret encryption          | release binary / brew |
| age        | sops age key backend       | release binary / brew |

## Install uv

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
```

Alternatively, Homebrew:

```bash
brew install uv
```

uv installs into `~/.local/bin` by default. Add it to `PATH` if needed:

```bash
export PATH="$PATH:$HOME/.local/bin"
```

Verify:

```bash
uv --version
```

Set up the project dependencies and hooks from the repo root:

```bash
uv sync --all-extras --dev   # install dependencies
uv run pytest                # run tests
uv run pre-commit install    # install pre-commit hooks
```

`uv run pre-commit install` registers two git hooks: `pre-commit` (lint, format, secrets) and `commit-msg` (Conventional Commits). The first `pre-commit` run downloads the hook environments from the internet; on the sandboxed runner this may hit the network policy.

Verify the hooks are registered:

```bash
ls .git/hooks/pre-commit .git/hooks/commit-msg
git commit --dry-run   # runs the pre-commit stage against staged files
```

To run the full gate set without committing (the intended local CI pass):

```bash
uv run pre-commit run --all-files
```

`scripts/link_adr.py` validates ADR cross-references and keeps decision links current, exercised via the pytest and pre-commit runs above.

The `ansible-lint` pre-commit hook lints the whole `ansible/` tree and needs the collections from `ansible/requirements.yaml` on disk. Install them once with:

```bash
uv run --with ansible-core ansible-galaxy collection install -r ansible/requirements.yaml
```

## Install kubeconform and tflint

Used by the `kubeconform` and `terraform_tflint` pre-commit hooks; not managed by the switchers. The release installs below put the binaries in `$HOME/bin`, which must be on `PATH` (same note as in the version switchers section below).

Linux release binaries:

```bash
# kubeconform (replace v0.8.0 with the current release)
curl -L https://github.com/yannh/kubeconform/releases/download/v0.8.0/kubeconform-linux-amd64.tar.gz -o /tmp/kubeconform.tgz
tar -xzf /tmp/kubeconform.tgz -C /tmp kubeconform
install -m 0755 /tmp/kubeconform "$HOME/bin/kubeconform"

# tflint (replace v0.64.0 with the current release)
curl -L https://github.com/terraform-linters/tflint/releases/download/v0.64.0/tflint_linux_amd64.zip -o /tmp/tflint.zip
unzip -o /tmp/tflint.zip -d /tmp/tflint
install -m 0755 /tmp/tflint/tflint "$HOME/bin/tflint"
```

Homebrew:

```bash
brew install kubeconform tflint
```

Verify both:

```bash
kubeconform -v
tflint --version
```

Note, `kubeconform` fetches CRD schemas from the internet on first run; the sandboxed network policy may block this.

## Install version switchers

Installing the switchers once is enough; they fetch and install the exact OpenTofu and Terragrunt versions.

Linux, using the official scripts:

```bash
curl -L https://raw.githubusercontent.com/warrensbox/terraform-switcher/master/install.sh | bash
curl -L https://raw.githubusercontent.com/warrensbox/tgswitch/release/install.sh | bash
```

macOS, using Homebrew:

```bash
brew install warrensbox/tap/tfswitch
brew install warrensbox/tap/tgswitch
```

Note, `tfswitch` installs binaries into `$HOME/bin` by default (fallback when `/usr/local/bin` is not writable). Add it to `PATH` if needed:

```bash
export PATH="$PATH:$HOME/bin"
```

## Install OpenTofu with tfswitch

`tfswitch` manages Terraform and OpenTofu. Use the `--product opentofu` flag to target OpenTofu:

```bash
# latest stable release
tfswitch --product opentofu --latest

# or a specific version
tfswitch --product opentofu 1.12.5
```

Downloads are verified against the OpenTofu checksums and PGP key. The active binary is symlinked as `tofu`. Verify:

```bash
tofu --version
```

## Install Terragrunt with tgswitch

```bash
# a specific version
tgswitch 1.1.2

# or pin in a shim file; tgswitch reads it from the working directory
echo "1.1.2" > .terragrunt-version
tgswitch
```

The active binary is symlinked as `terragrunt`. Verify:

```bash
terragrunt --version
```

For the latest release, check the version on the [Terragrunt releases page](https://github.com/gruntwork-io/terragrunt/releases) and pass it explicitly, or write it to `.terragrunt-version` in this repo so every tgswitch run picks it up.

## Install sops and age

age and sops are not managed by the switchers. Install age first, then use it as the sops age key backend.

Linux release binaries:

```bash
# age (replace v1.3.1 with the current release)
curl -L https://github.com/FiloSottile/age/releases/download/v1.3.1/age-v1.3.1-linux-amd64.tar.gz -o /tmp/age.tar.gz
tar -xzf /tmp/age.tar.gz -C /tmp
sudo install -m 0755 /tmp/age/age /usr/local/bin/age

# sops (replace v3.13.3 with the current release)
sudo install -m 0755 \
  <(curl -L https://github.com/getsops/sops/releases/download/v3.13.3/sops-v3.13.3.linux.amd64) \
  /usr/local/bin/sops
```

Homebrew:

```bash
brew install sops age
```

Verify both:

```bash
sops --version
age --version
```

## sops age key

sops encrypts secrets in-git with age. The decryption key is never committed. Create one and register it with sops:

```bash
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
```

Export the public key to your password manager; it is the recipient listed in `.sops.yaml`. sops finds `keys.txt` automatically, or point `SOPS_AGE_KEY_FILE` at it.

## Expected versions

Run this after installing. It should print non-empty versions:

```bash
tfswitch --version && tgswitch --version
tofu --version && terragrunt --version
sops --version && age --version
uv run pre-commit --version
```

The last line verifies the pre-commit hooks (from the uv dependency) are runnable; the hooks themselves are registered by `uv run pre-commit install` in the setup step above.

## Verify the IaC

Syntax only, no providers or live values needed:

```bash
tofu fmt -check -recursive infrastructure/catalogs
terragrunt hcl fmt --check
```

Full validation that resolves modules and providers, but needs an age key and network access to the provider registry:

```bash
cd infrastructure && terragrunt run validate
```

For a stack (`infrastructure/stacks/`), validate via the stack runner:

```bash
cd infrastructure/stacks/public/proxmox && terragrunt stack run validate
```
