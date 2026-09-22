#!/usr/bin/env bash
# Fill authentik slice placeholder tokens on the host.
# Sources values from SOPS-encrypted infrastructure/secrets.yaml.
# Idempotent: already-filled files are detected and skipped, except that a
# generated database password is reused to keep db-secret and config-secret
# in sync. Never prints secret values. Requires the host age key
# (SOPS_AGE_KEY, SOPS_AGE_KEY_FILE, or the default age key file).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

die() {
  echo "error: $*" >&2
  exit 1
}

command -v sops >/dev/null 2>&1 || die "sops not found"
command -v openssl >/dev/null 2>&1 || die "openssl not found"
command -v sed >/dev/null 2>&1 || die "sed not found"

SECRETS=infrastructure/secrets.yaml
DIR=kubernetes/infrastructure/authentik
DB="$DIR/db-secret.yaml"
CFG="$DIR/config-secret.yaml"
BUP="$DIR/backup-secret.yaml"
CLUSTER="$DIR/cluster.yaml"
APPS=(
  kubernetes/infrastructure/private/apps/authentik.yaml
  kubernetes/infrastructure/private/apps/authentik-infra.yaml
  kubernetes/infrastructure/private/apps/authentik-route.yaml
)

extract() {
  sops --decrypt --extract "$1" "$SECRETS"
}

# Escape a replacement string for sed with | as delimiter.
esc() {
  printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'
}

token_present() {
  local out
  out="$(sops --decrypt "$1")"
  [[ "$out" == *"$2"* ]]
}

plain_token_present() {
  local file="$1"
  local token="$2"
  [[ "$(<"$file")" == *"$token"* ]]
}

# fill FILE TOKEN VALUE [TOKEN VALUE ...]
# Decrypts FILE, substitutes tokens, re-encrypts with the creation rule for
# FILE's path. Increments UPDATED when a substitution runs.
UPDATED=0
fill() {
  local file="$1"
  shift
  local exprs=()
  while [ "$#" -ge 2 ]; do
    exprs+=(-e "s|$1|$(esc "$2")|g")
    shift 2
  done
  local tmp
  tmp="$(mktemp)"
  sops --decrypt "$file" | sed "${exprs[@]}" \
    | sops --encrypt --input-type yaml --output-type yaml \
        --filename-override "$file" /dev/stdin >"$tmp"
  mv "$tmp" "$file"
  UPDATED=$((UPDATED + 1))
}

fill_plain() {
  local file="$1"
  local token="$2"
  local value="$3"
  local tmp
  tmp="$(mktemp)"
  sed -e "s|$(esc "$token")|$(esc "$value")|g" "$file" >"$tmp"
  mv "$tmp" "$file"
  UPDATED=$((UPDATED + 1))
}

fill_plain() {
  local file="$1"
  local token="$2"
  local value="$3"
  local tmp
  tmp="$(mktemp)"
  sed -e "s|$(esc "$token")|$(esc "$value")|g" "$file" >"$tmp"
  mv "$tmp" "$file"
  UPDATED=$((UPDATED + 1))
}

GARAGE_HOST="$(extract '["network_config"]["garage_lxc"]["ip"]' || true)"
GARAGE_AK="$(extract '["garage"]["s3"]["access_key_id"]' || true)"
GARAGE_SK="$(extract '["garage"]["s3"]["secret_access_key"]' || true)"
GITEA_URL="$(extract '["gitea"]["url"]' || true)"

[ -n "$GARAGE_HOST" ] || die "empty or missing network_config.garage_lxc.ip"
[ -n "$GARAGE_AK" ] || die "empty or missing garage.s3.access_key_id"
[ -n "$GARAGE_SK" ] || die "empty or missing garage.s3.secret_access_key"
[ -n "$GITEA_URL" ] || die "empty or missing gitea.url"

# Keep db-secret and config-secret on the same password across runs.
DB_PW=""
if token_present "$DB" "__BOOTSTRAP_DB_PASSWORD__"; then
  DB_PW="$(openssl rand -base64 24)"
else
  DB_PW="$(sops --decrypt --extract '["stringData"]["password"]' "$DB" || true)"
fi
[ -n "$DB_PW" ] || die "cannot resolve database password"

if token_present "$DB" "__BOOTSTRAP_DB_PASSWORD__"; then
  fill "$DB" "__BOOTSTRAP_DB_PASSWORD__" "$DB_PW"
fi

if token_present "$CFG" "__BOOTSTRAP_DB_PASSWORD__" ||
  token_present "$CFG" "__BOOTSTRAP_SECRET_KEY__"; then
  SECRET_KEY="$(openssl rand -base64 32)"
  # Only substitute tokens still present; a rerun leaves filled values alone.
  EXPRS=()
  if token_present "$CFG" "__BOOTSTRAP_DB_PASSWORD__"; then
    EXPRS+=("__BOOTSTRAP_DB_PASSWORD__" "$DB_PW")
  fi
  if token_present "$CFG" "__BOOTSTRAP_SECRET_KEY__"; then
    EXPRS+=("__BOOTSTRAP_SECRET_KEY__" "$SECRET_KEY")
  fi
  fill "$CFG" "${EXPRS[@]}"
fi

if token_present "$CLUSTER" "__GARAGE_LXC_HOST__"; then
  fill "$CLUSTER" "__GARAGE_LXC_HOST__" "$GARAGE_HOST"
fi

if token_present "$BUP" "__GARAGE_ACCESS_KEY_ID__" ||
  token_present "$BUP" "__GARAGE_ACCESS_SECRET_KEY__"; then
  EXPRS=()
  if token_present "$BUP" "__GARAGE_ACCESS_KEY_ID__"; then
    EXPRS+=("__GARAGE_ACCESS_KEY_ID__" "$GARAGE_AK")
  fi
  if token_present "$BUP" "__GARAGE_ACCESS_SECRET_KEY__"; then
    EXPRS+=("__GARAGE_ACCESS_SECRET_KEY__" "$GARAGE_SK")
  fi
  fill "$BUP" "${EXPRS[@]}"
fi

for app in "${APPS[@]}"; do
  if plain_token_present "$app" "__GITEA_REPO_URL__"; then
    fill_plain "$app" "__GITEA_REPO_URL__" "$GITEA_URL"
  fi
done

echo "bootstrap fill complete: $UPDATED file(s) updated, no values printed"
