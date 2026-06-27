#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Netresearch DTT GmbH
#
# Regression tests for bin/env-set.sh — the idempotent .env mutator.
# Each test gets a fresh fake repo root in $BATS_TEST_TMPDIR (see
# tests/bin/test_helper.bash).

load test_helper

setup() {
  setup_fake_repo ""
}

# ---------------------------------------------------------------------
# Core behavior
# ---------------------------------------------------------------------

@test "env-set: appends a brand-new key" {
  run ./bin/env-set.sh FOO bar
  [ "$status" -eq 0 ]
  run grep -c '^FOO=bar$' .env
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "env-set: replaces existing key (no duplicate line)" {
  setup_fake_repo $'FOO=old\nBAR=keep\n'
  run ./bin/env-set.sh FOO new
  [ "$status" -eq 0 ]
  # Exactly one FOO line, with the new value.
  [ "$(grep -c '^FOO=' .env)" -eq 1 ]
  grep -q '^FOO=new$' .env
  # Untouched keys survive.
  grep -q '^BAR=keep$' .env
}

@test "env-set: empty VALUE clears the key (KEY= line preserved)" {
  setup_fake_repo $'FOO=something\n'
  run ./bin/env-set.sh FOO ""
  [ "$status" -eq 0 ]
  # Line is rewritten as FOO=, not removed entirely.
  grep -qx 'FOO=' .env
  [ "$(grep -c '^FOO=' .env)" -eq 1 ]
}

@test "env-set: VALUE absent defaults to empty (KEY= appended)" {
  run ./bin/env-set.sh FOO
  [ "$status" -eq 0 ]
  grep -qx 'FOO=' .env
}

# ---------------------------------------------------------------------
# Error paths
# ---------------------------------------------------------------------

@test "env-set: missing .env exits 1 with a clean message" {
  rm -f .env
  run ./bin/env-set.sh FOO bar
  [ "$status" -eq 1 ]
  [[ "$output" == *".env not found"* ]]
  [[ "$output" == *"make init"* ]]
}

@test "env-set: rejects newline in VALUE" {
  run ./bin/env-set.sh FOO $'a\nb'
  [ "$status" -eq 1 ]
  [[ "$output" == *"VALUE must not contain newlines"* ]]
  # Nothing was written.
  ! grep -q '^FOO' .env
}

@test "env-set: rejects KEY with whitespace" {
  run ./bin/env-set.sh "BAD KEY" value
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid KEY"* ]]
}

@test "env-set: rejects KEY starting with a digit" {
  run ./bin/env-set.sh 1FOO value
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid KEY"* ]]
}

@test "env-set: rejects KEY containing a dash" {
  run ./bin/env-set.sh "FOO-BAR" value
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid KEY"* ]]
}

@test "env-set: missing KEY (no args) exits 1 with usage" {
  run ./bin/env-set.sh
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage:"* ]]
}

# ---------------------------------------------------------------------
# Special-character passthrough — the whole point of the awk/ENVIRON
# replacement is that sed-escape landmines never apply.
# ---------------------------------------------------------------------

@test "env-set: VALUE with \$, &, /, \\, !, special chars passes through unchanged" {
  local special='$dollar&amp/slash\back!bang"quote'
  run ./bin/env-set.sh FOO "$special"
  [ "$status" -eq 0 ]
  # grep -F: fixed string, no regex interpretation.
  grep -Fxq "FOO=$special" .env
}

@test "env-set: replacing a value containing \$ literal works (regex-meta in current value)" {
  setup_fake_repo $'FOO=$BAR\n'
  run ./bin/env-set.sh FOO new
  [ "$status" -eq 0 ]
  grep -qx 'FOO=new' .env
  [ "$(grep -c '^FOO=' .env)" -eq 1 ]
}

# ---------------------------------------------------------------------
# File-mode and atomicity
# ---------------------------------------------------------------------

@test "env-set: preserves .env mode 0600 across mutation" {
  setup_fake_repo $'FOO=old\n'
  [ "$(env_mode)" = "600" ]
  run ./bin/env-set.sh FOO new
  [ "$status" -eq 0 ]
  [ "$(env_mode)" = "600" ]
}

@test "env-set: preserves an unusual mode (0640)" {
  setup_fake_repo $'FOO=old\n'
  chmod 0640 .env
  run ./bin/env-set.sh FOO new
  [ "$status" -eq 0 ]
  [ "$(env_mode)" = "640" ]
}

@test "env-set: leaves no .env.XXXXXX tmp file after a successful run" {
  run ./bin/env-set.sh FOO bar
  [ "$status" -eq 0 ]
  assert_no_env_tmp_leftover
}

@test "env-set: leaves no .env.XXXXXX tmp file after a rejected VALUE (newline)" {
  run ./bin/env-set.sh FOO $'a\nb'
  [ "$status" -eq 1 ]
  assert_no_env_tmp_leftover
}

# ---------------------------------------------------------------------
# Ordering / unrelated lines
# ---------------------------------------------------------------------

@test "env-set: preserves comments, blank lines, and order on replace" {
  setup_fake_repo $'# header\n\nKEEP_BEFORE=1\nFOO=old\n# inline\nKEEP_AFTER=2\n'
  run ./bin/env-set.sh FOO new
  [ "$status" -eq 0 ]
  # Exact byte-for-byte file content preserved (blank line at row 2,
  # comments untouched, FOO updated in place between KEEP_BEFORE and
  # KEEP_AFTER). diff is the cleanest assertion here — bats 1.13's
  # `lines` array does not reliably preserve blank lines.
  diff -u .env - <<'EOF'
# header

KEEP_BEFORE=1
FOO=new
# inline
KEEP_AFTER=2
EOF
}
