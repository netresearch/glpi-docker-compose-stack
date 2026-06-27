#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Netresearch DTT GmbH
#
# env-set.sh KEY VALUE — idempotent .env mutator.
#
# If KEY exists in .env, replaces its value; otherwise appends KEY=VALUE.
# Preserves comments, blank lines, and ordering of other keys.
#
# VALUE is taken verbatim — special characters (slashes, ampersands,
# quotes) are passed through unchanged via awk's ENVIRON, side-stepping
# sed-escaping landmines.

set -euo pipefail

if [[ $# -lt 1 || -z "${1:-}" ]]; then
  echo "Usage: $0 KEY [VALUE]" >&2
  echo "       Empty VALUE clears the key (sets KEY=)." >&2
  exit 1
fi

KEY="$1"
VALUE="${2:-}"
ENV_FILE="${ENV_FILE:-.env}"

cd "$(cd "$(dirname "$0")/.." && pwd)"

[[ -f "$ENV_FILE" ]] || { echo "env-set: $ENV_FILE not found — run \`make init\` first" >&2; exit 1; }

# Validate KEY: shell-portable identifier, no spaces/quotes.
[[ "$KEY" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo "env-set: invalid KEY: $KEY" >&2; exit 1; }

# Reject newlines in VALUE — a literal LF would inject a second key into
# .env (the awk replacement only rewrites the first line, leaving the
# tail of a multi-line value dangling as bareword lines).
[[ "$VALUE" != *$'\n'* ]] || { echo "env-set: VALUE must not contain newlines" >&2; exit 1; }

# Create the temp file in the same directory as $ENV_FILE so the final
# `mv` is atomic (rename(2) only guarantees atomicity within a filesystem).
tmp=$(mktemp "${ENV_FILE}.XXXXXX")
trap 'rm -f "$tmp"' EXIT

if grep -q "^${KEY}=" "$ENV_FILE"; then
  VALUE_PASS="$VALUE" awk -v key="$KEY" '
    BEGIN { prefix = key "="; val = ENVIRON["VALUE_PASS"] }
    {
      if (substr($0, 1, length(prefix)) == prefix) {
        print prefix val
      } else {
        print $0
      }
    }
  ' "$ENV_FILE" > "$tmp"
else
  cp "$ENV_FILE" "$tmp"
  printf '%s=%s\n' "$KEY" "$VALUE" >> "$tmp"
fi

# Preserve .env's existing mode (init.sh writes umask 077 → 0600).
# Linux stat uses `-c '%a'` (numeric); BSD/macOS stat uses `-f '%Lp'`.
# Plain `-f '%A'` on BSD returns a symbolic mode string ("rw-------"),
# which chmod doesn't accept — use `%Lp` for the lower-12-bits numeric.
mode=$(stat -c '%a' "$ENV_FILE" 2>/dev/null || stat -f '%Lp' "$ENV_FILE")
mv "$tmp" "$ENV_FILE"
chmod "$mode" "$ENV_FILE"
trap - EXIT

printf '\033[1;34m[env-set]\033[0m %s\n' "$KEY"
