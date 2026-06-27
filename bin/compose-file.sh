#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Netresearch DTT GmbH
#
# compose-file.sh — manage docker compose overlays via COMPOSE_FILE in .env.
#
# Docker compose reads COMPOSE_FILE from .env automatically (Compose v2+)
# and applies the listed files as overlays in order. This script
# idempotently adds / removes paths so `make up` works without manual
# `-f compose.yml -f examples/compose.X.yml` chaining.
#
# Usage:
#   compose-file.sh add    examples/compose.bugsink.yml [more.yml ...]
#   compose-file.sh remove examples/compose.bugsink.yml [more.yml ...]
#   compose-file.sh list
#
# The base `compose.yml` is always implied — if COMPOSE_FILE is unset or
# blank, compose still reads compose.yml + compose.override.yml on its
# own. This script only manages overlays beyond the base.

set -euo pipefail

SEP=":"
BASE="compose.yml"
ENV_FILE="${ENV_FILE:-.env}"

cd "$(cd "$(dirname "$0")/.." && pwd)"

[[ -f "$ENV_FILE" ]] || { echo "compose-file: $ENV_FILE not found — run \`make init\` first" >&2; exit 1; }

action="${1:-}"
case "$action" in
  add|remove|list) shift ;;
  *) echo "Usage: $0 add|remove|list [PATH...]" >&2; exit 1 ;;
esac

# Read COMPOSE_FILE tolerantly: allow optional spaces around `=` and
# optional surrounding double/single quotes (operators sometimes hand-edit
# the file). env-set.sh always writes bare values, so this only matters
# for hand-edited cases.
current="$(awk '/^[[:space:]]*COMPOSE_FILE[[:space:]]*=/ {
    sub(/^[[:space:]]*COMPOSE_FILE[[:space:]]*=[[:space:]]*/, "");
    print; exit
}' "$ENV_FILE" || true)"
case "$current" in
  '"'*'"') current="${current#\"}"; current="${current%\"}" ;;
  "'"*"'") current="${current#\'}"; current="${current%\'}" ;;
  *) ;;  # bare/unquoted — pass through unchanged
esac
[[ -z "$current" ]] && current="$BASE"

case "$action" in
  list)
    # One path per line for human + grep consumption.
    printf '%s\n' "$current" | tr "$SEP" '\n'
    exit 0
    ;;
  add)
    [[ $# -gt 0 ]] || { echo "compose-file add: at least one PATH required" >&2; exit 1; }
    for p in "$@"; do
      # Only allow examples/compose.*.yml — anything else is either a typo
      # or someone wiring an untrusted compose file into the stack.
      case "$p" in
        examples/compose.*.yml) ;;
        *) echo "compose-file: only examples/compose.*.yml paths are allowed (got: $p)" >&2; exit 1 ;;
      esac
      [[ -f "$p" ]] || { echo "compose-file: $p not found" >&2; exit 1; }
      # Use boundaries to avoid partial-string matches (e.g. "a.yml"
      # matching "ab.yml"). Wrapping with SEP on both sides + matching
      # against a SEP-wrapped haystack gives clean boundaries.
      if printf '%s%s%s' "$SEP" "$current" "$SEP" | grep -Fq "$SEP$p$SEP"; then
        printf '\033[1;34m[compose-file]\033[0m %s already enabled\n' "$p"
      else
        current="$current$SEP$p"
        printf '\033[1;32m[compose-file]\033[0m + %s\n' "$p"
      fi
    done
    ;;
  remove)
    [[ $# -gt 0 ]] || { echo "compose-file remove: at least one PATH required" >&2; exit 1; }
    for p in "$@"; do
      # Remove "<SEP>$p" or "$p<SEP>" or standalone (would never be
      # base — base stays). Use awk for safe path-with-slashes handling.
      new="$(P="$p" awk -v sep="$SEP" '
        BEGIN { p = ENVIRON["P"] }
        {
          n = split($0, parts, sep)
          first = 1
          out = ""
          for (i = 1; i <= n; i++) {
            if (parts[i] == p) continue
            if (first) { out = parts[i]; first = 0 }
            else       { out = out sep parts[i] }
          }
          print out
        }
      ' <<<"$current")"
      if [[ "$new" == "$current" ]]; then
        printf '\033[1;34m[compose-file]\033[0m %s was not enabled\n' "$p"
      else
        current="$new"
        printf '\033[1;33m[compose-file]\033[0m - %s\n' "$p"
      fi
    done
    ;;
  *)
    # Unreachable — the action-validating case at top of this script
    # already rejects anything outside add|remove|list. Belt-and-suspenders
    # default arm for SonarCloud's shelldre:S131 (defense-in-depth in
    # case the upstream validation is ever weakened).
    echo "compose-file: internal error — unhandled action '$action'" >&2
    exit 1
    ;;
esac

# If we're back to just the base, drop the COMPOSE_FILE line entirely so
# compose falls back to its own defaults (which include
# compose.override.yml auto-discovery).
script_dir="$(dirname "$0")"
if [[ "$current" == "$BASE" ]]; then
  if grep -q '^COMPOSE_FILE=' "$ENV_FILE"; then
    # env-set with empty value leaves COMPOSE_FILE= in place; we want it
    # GONE so compose's own default takes over. Strip the line directly.
    # Temp file in same dir → atomic rename(2); BSD/macOS stat uses
    # '%Lp' (numeric); '-f %A' would return the symbolic mode string.
    tmp=$(mktemp "${ENV_FILE}.XXXXXX")
    grep -v '^COMPOSE_FILE=' "$ENV_FILE" > "$tmp" || true
    mode=$(stat -c '%a' "$ENV_FILE" 2>/dev/null || stat -f '%Lp' "$ENV_FILE")
    mv "$tmp" "$ENV_FILE"
    chmod "$mode" "$ENV_FILE"
  fi
else
  "$script_dir/env-set.sh" COMPOSE_FILE "$current"
fi
