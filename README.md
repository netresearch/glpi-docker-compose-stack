<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- Copyright (c) 2026 Netresearch DTT GmbH -->

# glpi-docker-compose-stack

An opinionated, production-grade Docker Compose stack for **[GLPI](https://glpi-project.org) 11**, built around a hardened, single-purpose **php-fpm image** (published to `ghcr.io/netresearch/glpi-php-fpm`) with nginx, MariaDB, Valkey, a cron scheduler and nightly backups — wired together with the security and supply-chain rigor you'd want for an IT asset-management system that holds your whole estate.

Sibling of [`netresearch/snipe-it-docker-compose-stack`](https://github.com/netresearch/snipe-it-docker-compose-stack) and [`netresearch/phpbu-docker`](https://github.com/netresearch/phpbu-docker); same house style, GLPI internals.

> **Not affiliated with the GLPI project / Teclib'.** This packages upstream GLPI (GPL-3.0-or-later); the stack tooling here is MIT, the docs CC-BY-SA-4.0.

---

## Why this instead of the official image?

The official `glpi/glpi` image is Apache + mod_php in a single container with a built-in supervisor. This stack instead:

- **Decouples** PHP (php-fpm) from the web server (nginx) so each scales and updates independently, and php-fpm listens on a **unix socket only** (no FastCGI-over-TCP bypass surface).
- Builds GLPI from the **bundled release tarball** into a minimal, **multi-stage, non-root** image with the code layer **read-only** and only the state dirs writable.
- Serves from GLPI's **`public/` docroot** (mandatory in GLPI 11) with a strict **CSP** and security-header set.
- Ships **MariaDB with binlog** (point-in-time recovery), **Valkey** as GLPI's cache backend, **ofelia** running GLPI's `front/cron.php`, and **phpbu** for nightly DB + files + **encryption-key** backups.
- Multi-arch images (amd64/arm64) with **SLSA provenance, an in-image SBOM, and keyless cosign signatures**, rebuilt daily for base-image CVEs.

## Architecture

```
                         ┌──────────── host :8080 (loopback) / reverse proxy
                         ▼
                    ┌─────────┐   unix socket    ┌──────────────────┐
   browser ───────▶│   web   │◀────────────────▶│       app        │
                   │ nginx   │  /run/php-fpm/    │  glpi-php-fpm    │
                   │ public/ │   glpi.sock       │  (GLPI 11.0.8)   │
                   └─────────┘                   └───────┬──────────┘
                        ▲ static assets                  │ mysqli      ┌──────────┐
                        │ (glpi-public volume)           ├────────────▶│   db     │
                   ┌──────────┐                          │             │ mariadb  │
                   │app-assets│ one-shot public/ sync    │ cache       │ (binlog) │
                   └──────────┘                          ├────────────▶└──────────┘
                                                         │             ┌──────────┐
   ┌───────────┐  docker exec  front/cron.php (2 min)    └────────────▶│  valkey  │
   │ scheduler │──────────────▶ app                                    │  cache   │
   │  ofelia   │──────────────▶ backup (phpbu, nightly 03:00)          └──────────┘
   └───────────┘
```

| Service | Image | Role |
|---|---|---|
| `db` | `mariadb:11` | GLPI database, `ROW` binlog + durable fsync (PITR-ready) |
| `valkey` | `valkey:9-alpine` | GLPI core cache (RESP/redis-compatible), AOF persistence |
| `app-assets` | this image | one-shot: syncs `public/` into a volume nginx serves |
| `app` | `ghcr.io/netresearch/glpi-php-fpm` | GLPI on php-fpm, socket-only, non-root |
| `web` | `nginx:alpine` | serves `public/` + FastCGI to `app`, CSP/security headers |
| `scheduler` | `ghcr.io/netresearch/ofelia` | runs GLPI `front/cron.php` (2 min) + phpbu (nightly) |
| `backup` | `ghcr.io/netresearch/phpbu-docker` | nightly DB dump + `files/` + **config (crypt key)** archive |

## Quickstart

```bash
git clone https://github.com/netresearch/glpi-docker-compose-stack
cd glpi-docker-compose-stack

make init          # writes .env with random DB passwords (idempotent)
make up            # start the stack; first boot auto-installs GLPI

# wait until healthy, then:
open http://localhost:8080      # login: glpi / glpi  ← CHANGE IMMEDIATELY
```

First boot runs `bin/console database:install`, generating the schema **and** the
encryption key (`glpicrypt.key`, kept in the `glpi-config` volume). Every later
boot runs `database:update` to migrate the schema to the image's GLPI version.

GLPI ships several default accounts (`glpi`, `tech`, `normal`, `post-only`) all
with the password matching the username — **change or disable every one** before
exposing the instance.

## Configuration

All configuration is in `.env` (copy from `.env.example`; `make init` fills the
passwords). Key variables:

| Variable | Default | Purpose |
|---|---|---|
| `GLPI_IMAGE_TAG` | `latest` | image tag to run (pin to a version in prod) |
| `GLPI_DB_NAME` / `GLPI_DB_USER` / `GLPI_DB_PASSWORD` | `glpi` / `glpi` / — | database |
| `DB_ROOT_PASSWORD` | — | MariaDB root (init only) |
| `GLPI_CACHE_DSN` | `redis://valkey:6379` | GLPI cache backend |
| `GLPI_ENVIRONMENT_TYPE` | `production` | `production` hides debug surfaces |
| `GLPI_AUTOINSTALL` | `true` | install on first boot / upgrade thereafter |
| `SKIP_DB_UPDATE` | `false` | skip on-boot `database:update` (multi-replica) |
| `GLPI_HTTP_PORT` | `8080` | loopback host port for `web` |
| `GLPI_HOST` | `glpi.example.com` | public hostname (reverse-proxy overlays) |
| `TZ` | `Europe/Berlin` | container clock |

The image relocates GLPI's mutable state off the read-only code root via
`GLPI_CONFIG_DIR=/etc/glpi`, `GLPI_VAR_DIR=/var/lib/glpi/files`,
`GLPI_MARKETPLACE_DIR=/var/lib/glpi/plugins`, `GLPI_LOG_DIR=/var/log/glpi` —
each on its own named volume.

> **Uploads:** php and nginx allow **64 MB** request bodies by default (GLPI
> stores documents as attachments). Raise `upload_max_filesize`/`post_max_size`
> (php) and `client_max_body_size` (nginx) together for larger files. GLPI also
> only accepts uploads whose extension is in its *Document types* allow-list
> (Setup → Dropdowns → Document types) — add any custom types you need.

## Persistent data

| Volume | Mount | Contents | Back up? |
|---|---|---|---|
| `glpi-db-data` | db `/var/lib/mysql` | the database | yes (phpbu dumps it) |
| `glpi-config` | app `/etc/glpi` | `config_db.php` + **`glpicrypt.key`** | **yes — critical** |
| `glpi-var` | app `/var/lib/glpi/files` | uploads, cache, sessions, pictures | yes |
| `glpi-plugins` | app `/var/lib/glpi/plugins` | marketplace plugins | optional |
| `glpi-logs` | app `/var/log/glpi` | application logs | no |

> ⚠️ **Never delete `glpi-config`.** `glpicrypt.key` is the AES key for every
> encrypted DB field (stored credentials, plugin secrets). Lose it and that data
> is unrecoverable — which is why the nightly backup archives the config dir and
> the entrypoint refuses to regenerate the key.

## Operations

```bash
make logs                 # tail all services
make console -- glpi:cache:clear      # run any bin/console command
make ps                   # status
make down                 # stop (keep volumes)
```

- **Cron** — `ofelia` execs `php front/cron.php` in `app` every 2 minutes
  (GLPI's automatic actions). A heartbeat job feeds the `app` healthcheck, so a
  dead scheduler turns the container unhealthy. Set GLPI's *Automatic actions* to
  **CLI** mode (Setup → General → Automatic actions) for deterministic scheduling.
- **Upgrades** — bump `.glpi-version` (+ `GLPI_IMAGE_TAG`), `make up`; the
  entrypoint runs a maintenance-wrapped `database:update`.
- **Backups / restore** — see [`docs/runbook-restore.md`](docs/runbook-restore.md).
- **Day-2 ops** — see [`docs/runbook-day2-ops.md`](docs/runbook-day2-ops.md).
- **ofelia is host-wide:** with the docker socket mounted it runs the labelled
  jobs of **every** stack on the host — run only one labelled stack per host, or
  isolate the scheduler.

## TLS / reverse proxy

The `web` port is published on **loopback only**. Front it with one of the
overlays:

```bash
make enable-traefik        # or: enable-caddy
$EDITOR .env               # set GLPI_HOST
make up
```

See `examples/compose.traefik.yml`, `examples/compose.caddy.yml`, and
`examples/compose.observability.yml`.

## The image

Built from GLPI's bundled release tarball (`glpi-X.Y.Z.tgz`, vendor included) on
`php:8.4-fpm-alpine`. PHP extensions: `bcmath bz2 exif gd intl ldap mbstring
mysqli opcache redis sodium zip` plus the GLPI-required builtins. Runs as
`www-data` (root-owned, read-only code), `tini` PID 1, `SIGQUIT` graceful stop,
cgi-fcgi `/ping` healthcheck.

```bash
# Run a one-off console command against the published image:
docker run --rm ghcr.io/netresearch/glpi-php-fpm:latest \
  php /var/www/glpi/bin/console --version
```

Verify provenance and signatures:

```bash
gh attestation verify oci://ghcr.io/netresearch/glpi-php-fpm:11.0.8 \
  --owner netresearch
cosign verify ghcr.io/netresearch/glpi-php-fpm:11.0.8 \
  --certificate-identity-regexp 'https://github.com/netresearch/glpi-docker-compose-stack/.*' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

## Security posture

- Non-root, read-only code layer; php-fpm workers drop to `www-data`.
- `cap_drop: ALL` + `no-new-privileges` + `tmpfs` on app/web; socket-only FastCGI.
- nginx serves only `public/`; config, vendor and the files tree are unreachable.
- Enforcing CSP + standard security headers (see `config/nginx/snippets/`).
- MariaDB durable-by-default with binlog for PITR.
- Multi-arch images with SLSA provenance, SBOM and keyless cosign signatures,
  rebuilt daily for base-image CVEs.

Report vulnerabilities per [`SECURITY.md`](SECURITY.md).

## Development & contributing

```bash
make build        # build the image locally
make lint         # hadolint + shellcheck + yamllint + actionlint
make test         # container-structure-test + hardening-check + bats
```

See [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Licensing

- Stack tooling (Dockerfile, compose, scripts, CI): **MIT** — [`LICENSE-MIT`](LICENSE-MIT)
- Documentation: **CC-BY-SA-4.0** — [`LICENSE-CC-BY-SA-4.0`](LICENSE-CC-BY-SA-4.0)
- The packaged GLPI application: **GPL-3.0-or-later** (© the GLPI project / Teclib')
