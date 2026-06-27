<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- Copyright (c) 2026 Netresearch DTT GmbH -->

# GLPI Docker Compose Stack

> [!WARNING]
> **This project is no longer maintained.**
>
> Netresearch has moved away from GLPI to [GLPI](https://github.com/glpi-project/glpi) for asset management. As a result, this repository is **archived** and will receive no further updates, security patches, or support.
>
> The code remains available for reference and you are welcome to fork it, but use it at your own risk.

[![Build](https://github.com/netresearch/glpi-docker-compose-stack/actions/workflows/build.yml/badge.svg)](https://github.com/netresearch/glpi-docker-compose-stack/actions/workflows/build.yml)
[![Lint](https://github.com/netresearch/glpi-docker-compose-stack/actions/workflows/lint.yml/badge.svg)](https://github.com/netresearch/glpi-docker-compose-stack/actions/workflows/lint.yml)
[![Code: MIT](https://img.shields.io/badge/code-MIT-blue.svg)](LICENSE-MIT)
[![Content: CC-BY-SA-4.0](https://img.shields.io/badge/content-CC--BY--SA--4.0-green.svg)](LICENSE-CC-BY-SA-4.0)
[![Image: AGPL-3.0](https://img.shields.io/badge/image-AGPL--3.0-orange.svg)](https://github.com/grokability/glpi/blob/master/LICENSE)

Opinionated, hardened, **daily-built** self-hosted [GLPI](https://glpiapp.com/) asset-management deployment — a Docker Compose stack with our own slim **PHP 8.5 / Alpine** php-fpm image, an always-on Laravel scheduler + queue worker, scheduled `phpbu` backups, and dev overrides with mailpit and adminer for friction-free local development.

Made by [Netresearch DTT GmbH](https://www.netresearch.de/) on the back of a real GLPI inventory evaluation. Battle-scarred defaults, not a barebones starter.

## Try it in 60 seconds

```bash
git clone https://github.com/netresearch/glpi-docker-compose-stack.git
cd glpi-docker-compose-stack
make init   # bootstraps .env (APP_KEY + random DB passwords, idempotent)
make up     # docker compose up -d
# First boot pulls ~700 MB of images (~5 min on a typical link) and runs
# `php artisan migrate --force` (~60-90 s). When `make health` is green:
# visit http://localhost:8000
```

`make help` lists every target (artisan, backup, upgrade, health, …). For a full walkthrough see [Quick start](#quick-start) below.

<details>
<summary><strong>Table of contents</strong></summary>

- [What's in the stack](#whats-in-the-stack)
- [What's in our image](#whats-in-our-image)
- [Why does this exist?](#why-does-this-exist)
- [Quick start](#quick-start)
- [Common operations](#common-operations)
- [Dev mode](#dev-mode)
- [TLS / reverse proxy](#tls--reverse-proxy)
- [Image tags](#image-tags)
- [Configuration](#configuration)
- [Error tracking (Sentry / Bugsink)](#error-tracking-sentry--bugsink)
- [Security posture](#security-posture)
- [Backups](#backups)
- [Upgrading](#upgrading)
- [Operating the stack](#operating-the-stack)
- [Migrating from the upstream single-container image](#migrating-from-the-upstream-single-container-image)
- [Related projects](#related-projects)
- [Contributing](#contributing)
- [License](#license)

</details>

## What's in the stack

```
                          ┌────────────────────────────────────────────────┐
                          │  internal compose network (`glpi`)          │
                          │                                                │
   client ──HTTP──► web ──┼──► app  ── ghcr.io/netresearch/glpi-php-fpm   ◄── built daily
       (8000)    nginx    │     │    (php-fpm, handles web requests)
                 :alpine  │     │
                          │     ├──► worker ── same image, runs
                          │     │              `php artisan queue:work`
                          │     │
                          │     ├──► db      ── mariadb:11 (binlog enabled)
                          │     │
                          │     └──► valkey  ── valkey/valkey:9-alpine
                          │                                                │
                          │     scheduler ── ghcr.io/netresearch/ofelia    │
                          │       │ (runs `artisan schedule:run` per       │
                          │       │  minute and triggers nightly phpbu)    │
                          │       │                                        │
                          │       └─► backup ── ghcr.io/netresearch/phpbu-docker
                          │                                                │
                          │     one-shot init: app-assets populates the
                          │     shared `app-public` volume so nginx can
                          │     serve GLPI's public/ files statically.
                          └────────────────────────────────────────────────┘

   Only `web` is reachable from the host (port 8000 by default). Every other
   service (db, valkey, app, worker, scheduler, backup) has no host-published
   port in the default stack — they talk to each other on the internal network.
```

Seven long-running services plus a one-shot init:

| Service | Image | Purpose |
|---|---|---|
| **db** | `mariadb:11` | Primary store, binlog enabled for PITR |
| **valkey** | `valkey/valkey:9-alpine` | Cache + sessions + queue backend (Redis-compatible) |
| **app** | `ghcr.io/netresearch/glpi-php-fpm` | **Our** php-fpm image, GLPI app code |
| **web** | `nginx:alpine` | Static asset serving + fastcgi → `app` (unix socket) |
| **worker** | (same as `app`) | `php artisan queue:work` daemon — drains async jobs from valkey (emails, EOL reminders, etc.) |
| **scheduler** | `ghcr.io/netresearch/ofelia` | Label-driven cron for `artisan schedule:run` (per minute) **and** the nightly `phpbu` backup |
| **backup** | `ghcr.io/netresearch/phpbu-docker` | Nightly DB dump + uploads/storage tarball with retention policy |
| **app-assets** | (same as `app`) | One-shot init: syncs `public/` into the shared `app-public` volume |

[`compose.yml`](compose.yml) is the canonical reference — heavily commented with sizing, security, and resource-limit rationale.

## What's in our image

The php-fpm image (`ghcr.io/netresearch/glpi-php-fpm`) is intentionally narrow — just PHP + GLPI app code:

| | |
|---|---|
| **Base** | `php:8.5-fpm-alpine` |
| **PHP extensions** | bcmath, exif, gd, intl, ldap, mbstring, opcache, pdo_mysql, redis, xml, zip |
| **Runtime user** | `www-data` (non-root) |
| **Init** | `tini` as PID 1 → entrypoint → php-fpm |
| **Healthcheck** | `cgi-fcgi` ping on `/run/php-fpm/glpi.sock` |
| **Multi-arch** | linux/amd64, linux/arm64 |
| **Supply chain** | SLSA build provenance (in-toto via `attest-build-provenance`) + SBOM + keyless cosign signature (OIDC, Rekor-logged) on every push / scheduled build |
| **License** | AGPL-3.0-or-later (matches GLPI upstream) |

## Why does this exist?

The official `snipe/glpi` image is fine but conservative:
- ships PHP 8.3 (Ubuntu) or 8.4 (Alpine) — not the upstream-recommended 8.5
- the Alpine variant has no built-in scheduler, so Laravel's scheduled tasks (audit reminders, expected-checkin alerts, license expiry warnings) silently don't run
- new versions ship every 3-6 months — base-OS CVEs accrue between releases

This stack fixes all three:
1. **PHP 8.5** (upstream-supported via `composer.json` `^8.2`)
2. **Scheduler + queue worker run by default** via [ofelia](https://github.com/netresearch/ofelia) (Netresearch's fork) and a dedicated `worker` service — no in-container cron, no silently-dropped emails
3. **Daily rebuild** picks up Alpine + PHP + Composer-dep patches without waiting for an upstream GLPI release

Already running upstream `snipe/glpi`? See [Migrating from the upstream single-container image](#migrating-from-the-upstream-single-container-image).

## Quick start

```bash
git clone https://github.com/netresearch/glpi-docker-compose-stack.git
cd glpi-docker-compose-stack
make init                              # bootstraps .env (APP_KEY + random DB passwords, idempotent)
make up                                # docker compose up -d
make logs-app                          # Ctrl-C stops the tail (does NOT stop the stack)
# First boot pulls ~700 MB of images (~5 min on a typical link)
# and runs `php artisan migrate --force` (~60-90 s) — wait for the
# "ready — exec into CMD" line before opening the URL.
# Then open:  http://localhost:8000
```

For public deployments, set `APP_URL` in `.env` (no trailing slash) AFTER `make init` and run `make down && make up` to re-read env across all services (`make restart` only restarts `app` + `web`, so `worker` would keep emitting stale URLs in queued emails). The reverse-proxy overlay at [`examples/compose.traefik.yml`](examples/compose.traefik.yml) handles TLS termination.

## Common operations

| Goal | Command |
|---|---|
| Start / stop the stack | `make up` / `make down` |
| Restart `app` + `web` only (no env re-read) | `make restart` |
| Tail logs | `make logs-app` (one service) or `make logs` (all) |
| Aggregated health (wire into monitoring) | `make health` |
| One-shot artisan command | `make artisan CMD="route:list"` |
| Interactive Laravel REPL | `make tinker` |
| Shell inside `app` | `make shell` |
| On-demand backup | `make backup` (ofelia auto-runs nightly at 03:00) |
| Pull + recreate + tail | `make upgrade` |
| Show enabled overlays | `make overlays` |
| Enable an overlay | `make enable-traefik` / `make enable-caddy` / `make enable-observability` / `make enable-bugsink` |
| Disable an overlay | `make disable-traefik` / `make disable-caddy` / `make disable-observability` / `make disable-bugsink` |
| Wire external Sentry/Bugsink | `make enable-sentry DSN=https://...` / `make disable-sentry` |

`make help` is the canonical, always-current list.

## Dev mode

```bash
cp compose.override.yml.example compose.override.yml
docker compose up -d
```

Brings up the same stack plus:
- **mailpit** at <http://localhost:8025> — SMTP sink + web UI to catch outgoing notifications
- **adminer** at <http://localhost:8081> — DB browser
- Exposed db (3306) + valkey (6379) host ports for external clients
- `APP_DEBUG=true`, `APP_ENV=local`

## TLS / reverse proxy

The default `web` service binds plain HTTP on `${SNIPEIT_HTTP_PORT:-8000}`. Front it with your TLS terminator of choice. Two overlays ship in [`examples/`](examples/):

```bash
# Traefik (requires an existing traefik network)
docker compose -f compose.yml -f examples/compose.traefik.yml up -d

# Caddy
docker compose -f compose.yml -f examples/compose.caddy.yml up -d
```

For host-side nginx / HAProxy / your existing terminator, point it at `127.0.0.1:${SNIPEIT_HTTP_PORT}` and set `APP_URL=https://…` in `.env`. A Prometheus-scraping overlay also ships at [`examples/compose.observability.yml`](examples/compose.observability.yml).

## Image tags

Built daily, multi-arch (`linux/amd64` + `linux/arm64`), in two variants. Pinned (default) honours GLPI's `composer.lock`; rolling (suffix `-rolling`) re-resolves Composer ranges so CVE fixes in transitive deps land faster.

| Tag | Variant | Resolves to |
|---|---|---|
| `latest` | pinned | Latest stable GLPI release (tracks `.glpi-version`) |
| `8.5.0` | pinned | `refs/tags/v8.5.0` |
| `8.5.0-YYYYMMDD` | pinned | Reproducible dated build — audit-friendly |
| `8.5` / `8` | pinned | Auto-rolls on patch / minor bump |
| `master` / `develop` / `nightly` | pinned | Upstream branch HEAD |
| `master-rolling` / `develop-rolling` / `nightly-rolling` | rolling | Upstream branch HEAD with `composer.lock` deleted |
| `<tag>-rolling` | rolling | Same source ref as pinned, `composer.lock` deleted before `install` |
| `sha-pinned-<sha>` / `sha-rolling-<sha>` | both | Per-stack-commit build |

**Pick pinned for production** — reproducible, manifest-equivalent rebuilds (modulo base-image patches). **Pick rolling** if you'd rather catch transitive-dep CVEs early than match upstream's tested dependency graph.

**Rolling-variant caveat:** rolling builds can fail (and skip publishing) when upstream's `composer.json` references a major version of a dependency entirely covered by a Composer audit advisory — Composer refuses to install vulnerable packages by default. When this happens, the **pinned** image still ships because its lockfile pins the specific safe version upstream chose; the rolling tag lags until GLPI bumps its constraint. Watch the failed rolling job in CI to see which advisory tripped it.

Each image (both variants) ships a manifest at `/var/lib/glpi/deps.txt` — `docker exec <container> cat /var/lib/glpi/deps.txt` to see exactly which versions are installed.

## Configuration

[`.env.example`](.env.example) is the complete reference. Required vars:

| Variable | Description |
|---|---|
| `APP_KEY` | Laravel application key — generate once, never rotate |
| `APP_URL` | Public URL, no trailing slash |
| `DB_PASSWORD` | Application DB user password |
| `DB_ROOT_PASSWORD` | MariaDB root (only used at init) |

Operational toggles:

| Variable | Default | Description |
|---|---|---|
| `GLPI_IMAGE_TAG` | `latest` | Pin to a specific image build |
| `CACHE_DRIVER` / `SESSION_DRIVER` / `QUEUE_CONNECTION` | `redis` | Laravel driver names (RESP protocol). Flip to `file`/`file`/`sync` if you remove the valkey service |
| `SKIP_MIGRATIONS` | `false` | Skip `php artisan migrate --force` at container start |
| `TZ` | `UTC` | IANA timezone — sets the OS clock inside containers (log/cron timestamps) |
| `APP_TIMEZONE` | inherits `TZ` | What Laravel reads for date/time display; override only if it must diverge from `TZ` |
| `SENTRY_LARAVEL_DSN` | _(empty)_ | Error tracking DSN — empty disables; see [Error tracking](#error-tracking-sentry--bugsink) |

Docker secrets supported via `*_FILE` env vars (e.g. `DB_PASSWORD_FILE=/run/secrets/db_password`).

## Error tracking (Sentry / Bugsink)

The image ships `sentry/sentry-laravel` pre-installed. Set `SENTRY_LARAVEL_DSN` to your project DSN (`http(s)://<key>@<host>/<project-id>`) to start collecting errors; an empty DSN keeps the SDK silent (no network calls). [Bugsink](https://www.bugsink.com/) is recommended for self-hosting — it speaks the Sentry wire protocol and avoids the SaaS data-egress concern for an internal asset-management tool.

| Goal | Command |
|---|---|
| Point at an **external** Sentry/Bugsink instance | `make enable-sentry DSN=https://<key>@<host>/<project-id>` |
| Run a **self-hosted Bugsink** in-stack with auto-wired DSN | `make enable-bugsink` |
| Stop external reporting | `make disable-sentry` |
| Remove the in-stack Bugsink overlay | `make disable-bugsink` |
| Show what's currently enabled | `make overlays` |

Both `enable-*` targets mutate `.env`; after enabling, `make up` brings the configured stack up — no manual `-f` chaining. The Bugsink overlay adds a SQLite-backed `bugsink` service plus a one-shot `bugsink-init` container that seeds a project and writes its DSN into a tmpfs-backed shared volume; `app` and `worker` pick it up via `SENTRY_LARAVEL_DSN_FILE`. Re-runs are idempotent.

When fronting Bugsink with TLS, set `BUGSINK_PUBLIC_URL=https://bugsink.example.com` and `BUGSINK_BEHIND_HTTPS_PROXY=true` — see the comments in [`examples/compose.bugsink.yml`](examples/compose.bugsink.yml) for the `X-Forwarded-*` trust caveat (Traefik strips client-supplied headers by default; Caddy needs `trusted_proxies` configured). `BUGSINK_ADMIN_PASSWORD` is a bootstrap-only value — rotate it via the Bugsink UI on first login, then clear it from `.env`.

## Security posture

- **Non-root execution** — `www-data` runs php-fpm and queue:work; entrypoint drops privileges with `su-exec` after repairing volume permissions
- **No new privileges** — `security_opt: no-new-privileges:true` on every long-running service (db/valkey/app/web/worker/scheduler/backup, plus the bugsink overlay)
- **Capability drop** — `cap_drop: ALL` on `app`, `web`, and `worker` with minimal re-adds (see [`compose.yml`](compose.yml) for the per-service list); db/valkey/scheduler/backup keep default caps the upstream images expect
- **Overlay parity** — opt-in overlays in [`examples/`](examples/) (Bugsink, Traefik, Caddy, observability) ship with the same `no-new-privileges` + `cap_drop: ALL` posture on every long-running service they add
- **Read-only mounts** — nginx reads `app-public` and `app-storage` read-only
- **tmpfs** — `/tmp`, `/var/cache/nginx`, `/var/run` are tmpfs on `web`; `bootstrap/cache` is tmpfs on `app` (prevents attacker-written PHP from persisting across restarts)
- **Unix-socket-only php-fpm** — no TCP listener on 9000, so a sibling container on the glpi network can't bypass nginx and speak FastCGI directly to `app`
- **Pinned upstream** — GLPI git-tag-pinned via [`.glpi-version`](.glpi-version); base PHP + Alpine versions tag-pinned in [`Dockerfile`](Dockerfile) (rebuilt daily so re-tagged registry content is picked up)
- **Daily rebuild** — picks up base-image CVEs without waiting for upstream
- **Supply chain** — SLSA build provenance attestations (in-toto via [`attest-build-provenance`](https://github.com/actions/attest-build-provenance)), SBOM (BuildKit `sbom=true`), and a keyless cosign signature on the image manifest (OIDC, Rekor-logged) — all attached on every push and scheduled build
- **CVE scanning** — daily Trivy + osv-scanner runs (see [Actions → security](https://github.com/netresearch/glpi-docker-compose-stack/actions/workflows/security.yml)). Findings are informational, NOT CI gates — most flagged CVEs are in GLPI's upstream-pinned `composer.lock` (e.g. `phpseclib`, `onelogin/php-saml`) and need an upstream fix. Trivy SARIF uploads to GitHub code-scanning; subscribe via the repo Security tab for new-finding alerts.

## Backups

`phpbu` runs nightly at **03:00** (ofelia-driven) and produces three artefact families in the `backups` volume:

| Path | Contents | Retention |
|---|---|---|
| `db/glpi-db-*.sql.gz` | mariadb-dump (single-transaction) | rolling capacity (~5 GB) |
| `uploads/glpi-uploads-*.tar.gz` | GLPI uploads (`app-data` volume) | 30 days |
| `storage/glpi-storage-*.tar.gz` | Laravel storage (`app-storage` volume) | 30 days |

On-demand backup: `make backup`. Off-host shipping: bind-mount the `backups` volume into a destination synced by your existing tool (restic, rclone, NAS-attached cron). Disaster-recovery procedure: [`docs/runbook-restore.md`](docs/runbook-restore.md).

## Upgrading

```bash
make upgrade           # pulls latest images, recreates containers, follows logs
```

The `app` entrypoint runs `php artisan migrate --force` on every start. No DDL grant dance required — this stack's DB user is the app's own MariaDB account with full schema rights inside its database.

## Operating the stack

When something breaks, [`docs/runbook-day2-ops.md`](docs/runbook-day2-ops.md) catalogues the failure modes we know about — symptom → first check → recovery. Common ones:

- **App returns 500** — `make logs-app` (Laravel logs to stdout as JSON via `LOG_CHANNEL=stderr` + `LOG_STDERR_FORMATTER`)
- **Users randomly logged out** — Valkey LRU eviction; tune `--maxmemory` in `compose.yml` or switch to `SESSION_DRIVER=file`
- **`make up` complains about missing `.env`** — run `make init` first; the Makefile guard prevents the empty-root-password footgun
- **Backup-volume full** — `make backup-verify` flags it; tune retention in `config/phpbu/backup.json`

`make health` shows the aggregated health state of all containers and fails loudly when one is unhealthy — wire it into your existing monitoring.

## Migrating from the upstream single-container image

If you're moving from `snipe/glpi:vX.Y.Z-alpine` (Apache + PHP-FPM + cron in one container), follow [`docs/migration-from-upstream-single-container.md`](docs/migration-from-upstream-single-container.md). It covers volume mapping, env-var translation, and the cutover sequence (the upstream `STORAGE_DIR` and `PRIVATE_UPLOADS_DIR` aren't a 1:1 match for this stack's `app-data` / `app-storage` split).

## Related projects

- [grokability/glpi](https://github.com/grokability/glpi) — upstream GLPI itself
- [snipe/glpi](https://hub.docker.com/r/snipe/glpi) — official Docker image
- [netresearch/ofelia](https://github.com/netresearch/ofelia) — the scheduler this stack uses
- [netresearch/phpbu-docker](https://github.com/netresearch/phpbu-docker) — the backup engine this stack uses

## Contributing

PRs welcome. Standard community files (CONTRIBUTING / CODE_OF_CONDUCT / SECURITY) inherit from [Netresearch's org-level `.github` repo](https://github.com/netresearch/.github).

Security issues: please report via the standard Netresearch security contact rather than as a public issue.

## License

This repository uses split licensing — the right tool for each part:

| Path | License | Rationale |
|---|---|---|
| `Dockerfile`, `rootfs/`, `config/`, `compose*.yml`, `examples/`, `.github/`, `bin/`, `Makefile`, `tests/`, `renovate.json`, `.glpi-version` | [MIT](LICENSE-MIT) | Code and code-shaped configuration |
| `README.md`, `CHANGELOG.md`, `docs/**` | [CC-BY-SA-4.0](LICENSE-CC-BY-SA-4.0) | Prose and documentation — share-alike keeps forks open |

**The built image** (`ghcr.io/netresearch/glpi-php-fpm:*`) bundles AGPL-3.0 GLPI application code from [grokability/glpi](https://github.com/grokability/glpi). Redistribution of the image is bound by the upstream AGPL-3.0 terms in addition to MIT for our build glue.

This split follows the [Netresearch skill-repo licensing pattern](https://github.com/netresearch?q=skill).
