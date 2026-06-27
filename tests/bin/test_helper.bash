# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Netresearch DTT GmbH
#
# Shared bats setup for bin/ regression tests.
#
# Each test runs in its own $BATS_TEST_TMPDIR (bats provides a fresh one
# per-test). We materialise a minimal fake repo root there:
#
#   $BATS_TEST_TMPDIR/
#   ├── bin/
#   │   ├── env-set.sh        ← copy from real repo
#   │   └── compose-file.sh   ← copy from real repo
#   ├── examples/
#   │   ├── compose.bugsink.yml         (empty placeholder)
#   │   ├── compose.caddy.yml           (empty placeholder)
#   │   ├── compose.observability.yml   (empty placeholder)
#   │   └── compose.traefik.yml         (empty placeholder)
#   └── .env                  ← mode 0600, optional seed content
#
# Both helpers `cd "$(dirname "$0")/.."` to the repo root before
# touching anything, so invoking them as `$BATS_TEST_TMPDIR/bin/foo.sh ...`
# resolves the fake root naturally. We deliberately don't override
# ENV_FILE — the default `.env` resolution is what production uses, so
# that's what we test.

# Path to the *real* bin/ dir (where the source scripts live).
# Resolved once per test from the helper's own location:
#   tests/bin/test_helper.bash  →  ../../bin
REAL_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../bin" && pwd)"

# Load bats-support + bats-assert if available (installed by
# bats-core/bats-action in CI at /usr/lib/...). Local docker runs of
# bats/bats:latest also have them under /opt/bats/lib or /usr/lib.
# Fall back gracefully so missing libs surface as a clear skip rather
# than a cryptic "function not found" later.
_load_lib() {
  local lib="$1"
  local candidates=(
    "/usr/lib/bats-${lib}/load.bash"
    "/usr/lib/bats/bats-${lib}/load.bash"
    "/opt/bats/lib/bats-${lib}/load.bash"
  )
  for c in "${candidates[@]}"; do
    if [[ -f "$c" ]]; then
      # shellcheck disable=SC1090
      source "$c"
      return 0
    fi
  done
  return 1
}

_load_lib support || true
_load_lib assert || true

# Build the fake repo root in $BATS_TEST_TMPDIR and cd into it.
# Callers may pass an initial .env body via the first arg; default is
# an empty .env at mode 0600.
setup_fake_repo() {
  local env_seed="${1:-}"

  mkdir -p "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/examples"
  cp "$REAL_BIN/env-set.sh" "$BATS_TEST_TMPDIR/bin/env-set.sh"
  cp "$REAL_BIN/compose-file.sh" "$BATS_TEST_TMPDIR/bin/compose-file.sh"
  chmod +x "$BATS_TEST_TMPDIR/bin/"*.sh

  # Touch the four overlay files compose-file.sh accepts. Empty content
  # is fine — the script only stats them, never reads them.
  : > "$BATS_TEST_TMPDIR/examples/compose.bugsink.yml"
  : > "$BATS_TEST_TMPDIR/examples/compose.caddy.yml"
  : > "$BATS_TEST_TMPDIR/examples/compose.observability.yml"
  : > "$BATS_TEST_TMPDIR/examples/compose.traefik.yml"

  # Seed .env. umask 077 ensures the file is born at 0600 even before
  # the explicit chmod below — mirrors init.sh.
  ( umask 077 && printf '%s' "$env_seed" > "$BATS_TEST_TMPDIR/.env" )
  chmod 0600 "$BATS_TEST_TMPDIR/.env"

  cd "$BATS_TEST_TMPDIR" || return 1
}

# Assert no .env.XXXXXX tmp file is left behind by an atomic-mv path.
assert_no_env_tmp_leftover() {
  local leftover
  leftover=$(find "$BATS_TEST_TMPDIR" -maxdepth 1 -name '.env.??????' -print)
  if [[ -n "$leftover" ]]; then
    echo "leftover tmp file(s) under $BATS_TEST_TMPDIR:"
    echo "$leftover"
    return 1
  fi
}

# Read .env file mode as a 3-digit numeric string (e.g. "600").
env_mode() {
  stat -c '%a' "$BATS_TEST_TMPDIR/.env" 2>/dev/null \
    || stat -f '%Lp' "$BATS_TEST_TMPDIR/.env"
}
