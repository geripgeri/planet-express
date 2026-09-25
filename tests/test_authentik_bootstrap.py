from pathlib import Path

ROOT = Path(__file__).parents[1]


def test_garage_stack_has_dedicated_backup_unit():
    stack = (
        ROOT / "infrastructure/stacks/public/garage/terragrunt.stack.hcl"
    ).read_text()
    unit = (
        ROOT / "infrastructure/units/public/garage/k8s-backup/terragrunt.hcl"
    ).read_text()

    assert 'unit "k8s_backup"' in stack
    assert (
        'source = "${local.repo_root}/infrastructure/units/public/garage/k8s-backup"'
        in stack
    )
    assert 'path   = "k8s-backup"' in stack
    assert "create_bucket       = true" in unit
    assert "create_key          = true" in unit
    assert 'bucket_global_alias = "k8s-backup"' in unit
    assert 'key_name            = "authentik-backup"' in unit
    assert 'path = "${get_repo_root()}/infrastructure/root.hcl"' in unit
    assert (
        'source = "${local.repo_root}//infrastructure/catalogs/public/garage"' in unit
    )
    assert "garage.s3" not in unit


def test_bootstrap_uses_dedicated_backup_credentials():
    script = (ROOT / "scripts/bootstrap_authentik_env.sh").read_text()
    cluster = (ROOT / "kubernetes/infrastructure/authentik/cluster.yaml").read_text()

    assert '["garage"]["k8s_backup"]["access_key_id"]' in script
    assert '["garage"]["k8s_backup"]["secret_access_key"]' in script
    assert '["garage"]["s3"]["access_key_id"]' not in script
    assert '["stringData"]["ACCESS_KEY_ID"]' in script
    assert '["stringData"]["ACCESS_SECRET_KEY"]' in script
    assert script.count('set_sops_string "$BUP"') == 2
    assert "sops set --value-stdin" in script
    assert "name: authentik-backup" in cluster
    assert "key: ACCESS_KEY_ID" in cluster
    assert "key: ACCESS_SECRET_KEY" in cluster


def test_authentik_runbook_keeps_secrets_out_of_process_arguments():
    runbook = (ROOT / "docs/runbooks/authentik-deploy.md").read_text()

    assert "sops set --value-stdin infrastructure/secrets.yaml" in runbook
    assert runbook.count("sops set --value-stdin infrastructure/secrets.yaml") >= 4
    assert '"\\"$K8S_AK\\""' not in runbook
    assert '"\\"$K8S_SK\\""' not in runbook
    assert '"\\"$CSEC\\""' not in runbook
    assert "  terragrunt apply\n)" in runbook
    assert "  cd infrastructure/stacks/private/authentik\n" in runbook
    assert "  cd infrastructure/units/public/argocd\n  terragrunt apply\n)" in runbook
