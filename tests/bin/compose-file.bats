#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Netresearch DTT GmbH
#
# Regression tests for bin/compose-file.sh — the COMPOSE_FILE overlay
# manager. Each test gets a fresh fake repo root in $BATS_TEST_TMPDIR
# (see tests/bin/test_helper.bash).
#
# compose-file.sh delegates the actual .env mutation to env-set.sh
# (sibling under bin/), so the fake repo includes both scripts.
#
# The accepted overlay allow-list is exactly: traefik, caddy,
# observability. GLPI has no built-in error tracking, so (unlike the
# Snipe-IT sibling) there is no bugsink/sentry overlay — those are
# rejected even when the file exists.

load test_helper

setup() {
  setup_fake_repo ""
}

# ---------------------------------------------------------------------
# list
# ---------------------------------------------------------------------

@test "compose-file list: no COMPOSE_FILE → default compose.yml" {
  run ./bin/compose-file.sh list
  [ "$status" -eq 0 ]
  [ "$output" = "compose.yml" ]
}

@test "compose-file list: empty COMPOSE_FILE= → default compose.yml" {
  setup_fake_repo $'COMPOSE_FILE=\n'
  run ./bin/compose-file.sh list
  [ "$status" -eq 0 ]
  [ "$output" = "compose.yml" ]
}

@test "compose-file list: bare COMPOSE_FILE value splits on ':'" {
  setup_fake_repo $'COMPOSE_FILE=compose.yml:examples/compose.traefik.yml\n'
  run ./bin/compose-file.sh list
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "compose.yml" ]
  [ "${lines[1]}" = "examples/compose.traefik.yml" ]
}

@test "compose-file list: double-quoted COMPOSE_FILE strips quotes" {
  setup_fake_repo $'COMPOSE_FILE="compose.yml:examples/compose.caddy.yml"\n'
  run ./bin/compose-file.sh list
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "compose.yml" ]
  [ "${lines[1]}" = "examples/compose.caddy.yml" ]
}

@test "compose-file list: single-quoted COMPOSE_FILE strips quotes" {
  setup_fake_repo $'COMPOSE_FILE=\'compose.yml:examples/compose.caddy.yml\'\n'
  run ./bin/compose-file.sh list
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "compose.yml" ]
  [ "${lines[1]}" = "examples/compose.caddy.yml" ]
}

@test "compose-file list: tolerates spaces around '='" {
  setup_fake_repo $'COMPOSE_FILE = compose.yml:examples/compose.traefik.yml\n'
  run ./bin/compose-file.sh list
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "compose.yml" ]
  [ "${lines[1]}" = "examples/compose.traefik.yml" ]
}

# ---------------------------------------------------------------------
# add
# ---------------------------------------------------------------------

@test "compose-file add: valid path is appended to COMPOSE_FILE" {
  run ./bin/compose-file.sh add examples/compose.traefik.yml
  [ "$status" -eq 0 ]
  grep -qx 'COMPOSE_FILE=compose.yml:examples/compose.traefik.yml' .env
}

@test "compose-file add: idempotent — adding the same path twice yields one entry" {
  run ./bin/compose-file.sh add examples/compose.traefik.yml
  [ "$status" -eq 0 ]
  run ./bin/compose-file.sh add examples/compose.traefik.yml
  [ "$status" -eq 0 ]
  [[ "$output" == *"already enabled"* ]]
  # Count colons: exactly one separator → compose.yml + one overlay.
  local value
  value=$(awk -F= '/^COMPOSE_FILE=/{print $2}' .env)
  [ "$(tr -cd ':' <<<"$value" | wc -c)" -eq 1 ]
}

@test "compose-file add: multi-path single invocation enables both" {
  run ./bin/compose-file.sh add examples/compose.caddy.yml examples/compose.observability.yml
  [ "$status" -eq 0 ]
  grep -qx 'COMPOSE_FILE=compose.yml:examples/compose.caddy.yml:examples/compose.observability.yml' .env
}

@test "compose-file add: rejects path outside the overlay allow-list (absolute)" {
  # $BATS_TEST_TMPDIR is an absolute path, so this still verifies the
  # absolute-path rejection. Avoids /tmp permission/collision concerns.
  local external_file="$BATS_TEST_TMPDIR/external.yml"
  : > "$external_file"
  run ./bin/compose-file.sh add "$external_file"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown overlay"* ]]
  # .env was not mutated.
  ! grep -q '^COMPOSE_FILE=' .env
}

@test "compose-file add: rejects path-traversal style argument" {
  run ./bin/compose-file.sh add ../etc/passwd
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown overlay"* ]]
  ! grep -q '^COMPOSE_FILE=' .env
}

@test "compose-file add: rejects a dropped overlay (bugsink) even if the file exists" {
  # The bugsink overlay is intentionally NOT in the allow-list (GLPI has no
  # built-in error tracking). The allow-list check runs before the file
  # stat, so this is rejected even though setup_fake_repo created the file.
  [ -f examples/compose.bugsink.yml ]
  run ./bin/compose-file.sh add examples/compose.bugsink.yml
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown overlay"* ]]
  ! grep -q '^COMPOSE_FILE=' .env
}

@test "compose-file add: rejects an allow-listed overlay whose file is missing" {
  # traefik IS allow-listed, so it passes the allow-list gate and fails the
  # subsequent file-existence check — proving the stat guard still runs.
  rm -f examples/compose.traefik.yml
  run ./bin/compose-file.sh add examples/compose.traefik.yml
  [ "$status" -eq 1 ]
  [[ "$output" == *"not found"* ]]
  ! grep -q '^COMPOSE_FILE=' .env
}

@test "compose-file add: rejects an examples/ path outside the allow-list" {
  : > examples/random.yml
  run ./bin/compose-file.sh add examples/random.yml
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown overlay"* ]]
}

@test "compose-file add: missing PATH argument exits 1" {
  run ./bin/compose-file.sh add
  [ "$status" -eq 1 ]
  [[ "$output" == *"at least one PATH required"* ]]
}

# ---------------------------------------------------------------------
# remove
# ---------------------------------------------------------------------

@test "compose-file remove: removes an enabled overlay" {
  setup_fake_repo $'COMPOSE_FILE=compose.yml:examples/compose.traefik.yml:examples/compose.caddy.yml\n'
  run ./bin/compose-file.sh remove examples/compose.traefik.yml
  [ "$status" -eq 0 ]
  grep -qx 'COMPOSE_FILE=compose.yml:examples/compose.caddy.yml' .env
}

@test "compose-file remove: removing a path that wasn't enabled is a no-op (exit 0)" {
  setup_fake_repo $'COMPOSE_FILE=compose.yml:examples/compose.caddy.yml\n'
  run ./bin/compose-file.sh remove examples/compose.traefik.yml
  [ "$status" -eq 0 ]
  [[ "$output" == *"was not enabled"* ]]
  # .env unchanged.
  grep -qx 'COMPOSE_FILE=compose.yml:examples/compose.caddy.yml' .env
}

@test "compose-file remove: removing the last overlay strips COMPOSE_FILE= line entirely" {
  setup_fake_repo $'COMPOSE_FILE=compose.yml:examples/compose.traefik.yml\nOTHER=keep\n'
  run ./bin/compose-file.sh remove examples/compose.traefik.yml
  [ "$status" -eq 0 ]
  # No COMPOSE_FILE line at all → compose's own defaults take over.
  ! grep -q '^COMPOSE_FILE' .env
  # Unrelated keys survive.
  grep -qx 'OTHER=keep' .env
}

@test "compose-file remove: missing PATH argument exits 1" {
  run ./bin/compose-file.sh remove
  [ "$status" -eq 1 ]
  [[ "$output" == *"at least one PATH required"* ]]
}

# ---------------------------------------------------------------------
# Invalid action
# ---------------------------------------------------------------------

@test "compose-file: invalid action exits 1 with usage hint" {
  run ./bin/compose-file.sh foo
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "compose-file: no action exits 1 with usage hint" {
  run ./bin/compose-file.sh
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage:"* ]]
}

# ---------------------------------------------------------------------
# .env preconditions
# ---------------------------------------------------------------------

@test "compose-file: missing .env exits 1 with a clean message" {
  rm -f .env
  run ./bin/compose-file.sh list
  [ "$status" -eq 1 ]
  [[ "$output" == *".env not found"* ]]
  [[ "$output" == *"make init"* ]]
}

# ---------------------------------------------------------------------
# Atomic .env mutation — no stray tmp files
# ---------------------------------------------------------------------

@test "compose-file add: leaves no .env.XXXXXX tmp file" {
  run ./bin/compose-file.sh add examples/compose.traefik.yml
  [ "$status" -eq 0 ]
  assert_no_env_tmp_leftover
}

@test "compose-file remove (last overlay): leaves no .env.XXXXXX tmp file" {
  setup_fake_repo $'COMPOSE_FILE=compose.yml:examples/compose.traefik.yml\n'
  run ./bin/compose-file.sh remove examples/compose.traefik.yml
  [ "$status" -eq 0 ]
  assert_no_env_tmp_leftover
}

@test "compose-file: preserves .env mode 0600 across add+remove cycle" {
  setup_fake_repo $'FOO=keep\n'
  [ "$(env_mode)" = "600" ]
  run ./bin/compose-file.sh add examples/compose.traefik.yml
  [ "$status" -eq 0 ]
  [ "$(env_mode)" = "600" ]
  run ./bin/compose-file.sh remove examples/compose.traefik.yml
  [ "$status" -eq 0 ]
  [ "$(env_mode)" = "600" ]
}
