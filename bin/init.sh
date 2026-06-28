#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Netresearch DTT GmbH
#
# init.sh — generate random DB passwords and write them to .env.
#
# Idempotent: existing non-empty values are preserved; only empty/missing
# variables are populated.
#
# Note: GLPI has no APP_KEY to generate here. Its encryption key
# (glpicrypt.key) is created automatically by `database:install` on the app's
# first boot and stored in the `glpi-config` volume — never in .env.

set -euo pipefail

# Restrict file creation mode — passwords land in .env BEFORE the explicit
# chmod below, so umask is the only thing preventing a 0644 readable window.
umask 077

cd "$(cd "$(dirname "$0")/.." && pwd)" || { echo "init: cannot cd repo root" >&2; exit 1; }
[[ -f compose.yml ]] || { echo "init: compose.yml not found at repo root" >&2; exit 1; }

ENV_FILE=".env"
ENV_EXAMPLE=".env.example"

log()  { printf '\033[1;34m[init]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[init]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------
# 1. Bootstrap .env from .env.example if missing
# ---------------------------------------------------------------------
if [[ ! -f "$ENV_FILE" ]]; then
  [[ -f "$ENV_EXAMPLE" ]] || fail "$ENV_EXAMPLE not found — run from repo root"
  cp "$ENV_EXAMPLE" "$ENV_FILE"
  log "created $ENV_FILE from $ENV_EXAMPLE"
fi

# ---------------------------------------------------------------------
# 2. Helpers — read + write .env keys in place
# ---------------------------------------------------------------------
read_env() {
  local key="$1"
  awk -F= -v k="$key" '$1 == k { sub(/^[^=]*=/, ""); print }' "$ENV_FILE" | head -1
}

write_env() {
  # awk-based replacement — sidesteps sed-escaping pitfalls (&, \, etc.)
  local key="$1" value="$2" tmp
  tmp=$(mktemp)
  awk -v k="$key" -v v="$value" '
    BEGIN { done=0 }
    $0 ~ "^"k"=" { print k"="v; done=1; next }
    { print }
    END { if (!done) print k"="v }
  ' "$ENV_FILE" > "$tmp"
  mv "$tmp" "$ENV_FILE"
}

# 32 chars URL-safe base64; no '/', '+', '=' to avoid env-quoting surprises.
random_pw() {
  openssl rand -base64 32 | tr -d '/+=\n' | head -c 32
}

# ---------------------------------------------------------------------
# 3. DB passwords — generate random if empty
# ---------------------------------------------------------------------
for var in GLPI_DB_PASSWORD DB_ROOT_PASSWORD BACKUP_CRYPT_PASSWORD; do
  CUR=$(read_env "$var")
  if [[ -z "$CUR" ]]; then
    write_env "$var" "$(random_pw)"
    log "wrote $var=<32 random chars>"
  else
    log "$var already set — keeping"
  fi
done

# ---------------------------------------------------------------------
# 4. .env permissions — passwords inside, not world-readable
# ---------------------------------------------------------------------
chmod 0600 "$ENV_FILE"

cat <<'EOF'

  init complete — .env ready.

  Next:
    make up        # start the stack (db, valkey, app, web, scheduler, backup)
    make logs      # follow logs

  First boot auto-installs GLPI (login glpi / glpi) — change the default
  passwords immediately. Set GLPI_HOST + a reverse-proxy overlay for public
  exposure (examples/compose.traefik.yml).

EOF
