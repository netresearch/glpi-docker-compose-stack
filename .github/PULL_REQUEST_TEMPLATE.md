<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- Copyright (c) 2026 Netresearch DTT GmbH -->

## Title / Summary

<!-- One-line summary of what this PR changes and why. -->

## Type of change

- [ ] Bug fix (non-breaking change that fixes an issue)
- [ ] New feature (non-breaking change that adds functionality)
- [ ] Breaking change (fix or feature that would change existing behavior or interfaces)
- [ ] Documentation update
- [ ] CI / build / tooling change
- [ ] Refactor (no functional change)
- [ ] Security fix

## What changed

<!-- Bulleted list of concrete changes. Keep it focused — one logical change per PR. -->

-
-

## Why

<!-- Motivation, ticket/issue link, root cause if a bug fix. -->

Closes #

## Test plan

<!-- How did you verify this change? List the exact commands you ran. -->

- [ ] `make lint` passes locally
- [ ] `make test-image` passes locally
- [ ] `docker compose up -d` brings the stack up cleanly (`docker compose ps` all healthy)
- [ ] Manual smoke-test against `http://localhost:8000` (or documented alt entrypoint)
- [ ] For backup/restore changes: `make backup` and `make restore` exercised against a throwaway dataset

## Reviewer checklist

<!-- The author should tick these before requesting review. -->

- [ ] CI is green (lint, build, smoke-test, scorecard)
- [ ] `README.md` updated where user-visible behavior or env vars changed
- [ ] `CHANGELOG.md` updated under the "Unreleased" section
- [ ] `compose.override.yml.example` updated if a new override hook is introduced
- [ ] No secrets, tokens, or customer data in diffs or logs
- [ ] No AI-generated co-author trailers in commits
- [ ] Conventional Commit prefixes on all commits (`feat:`, `fix:`, `chore:`, `docs:`, `ci:`, `refactor:`)
- [ ] Commits are signed (`-S`) and signed off (`--signoff`)

## Breaking changes & migration notes

<!-- If "Breaking change" is ticked above: describe upgrade path, env var renames,
     data migrations, and the operator action required. Otherwise: write "None." -->

None.

## Screenshots / logs (optional)

<!-- Drag-and-drop or paste relevant CLI output / screenshots. -->
