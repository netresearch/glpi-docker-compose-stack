<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- Copyright (c) 2026 Netresearch DTT GmbH -->

# Runbook — Day-2 operations

Day-2 = "after `make up` works, before the first 3 AM incident". This file
catalogues the routine operations and the failure modes for **this** GLPI
stack (php-fpm + nginx, MariaDB, Valkey, ofelia, phpbu), with the exact
commands to run. Every claim here matches the shipped
`rootfs/usr/local/bin/entrypoint.sh` and `compose.yml`.

Two conventions used throughout:

- GLPI's CLI lives at `bin/console` (Symfony Console). Run it as the runtime
  user so anything it writes is owned correctly:
  `docker compose exec -u www-data app php bin/console <command>`.
- The code root `/var/www/glpi` is **read-only** (baked into the image). All
  mutable state lives on named volumes mounted off it — see the volume table
  at the bottom.

## Quick reference

| Symptom | First check | Likely cause |
|---|---|---|
| App returns 500 right after `up` | `docker compose logs app` | `database:update` failed — the entrypoint re-raises the non-zero rc and the container exits (see "Schema upgrade" below) |
| App returns 502 for 1-3 min after `up` | wait | first-boot `database:install`/`database:update` still running; the app healthcheck has a 180 s `start_period` |
| `glpicrypt.key MISSING` in `docker compose logs app` | restore the key | the `glpi-config` volume was lost/emptied while the DB is installed — encrypted DB fields are unreadable (see [runbook-restore.md](runbook-restore.md)) |
| Stored LDAP / mail-collector passwords stopped working | check `glpicrypt.key` | the encryption key changed or was regenerated |
| `db` won't start / app can't authenticate | `docker compose logs db` | empty `DB_ROOT_PASSWORD`, or password drift on an already-initialised data volume (see "Poisoned DB volume") |
| Automatic actions not firing | `docker compose logs scheduler` | ofelia lost the docker socket, labels drifted, or the heartbeat went stale |
| Marketplace can't download a plugin | egress + volume mode | no outbound HTTPS from `app`, or the `glpi-plugins` volume is read-only |
| Pages slow, DB load up | `docker compose exec valkey valkey-cli info memory` | Valkey cache evicting under memory pressure (see "Valkey cache pressure") |
| Backups missing from `/backups` | `docker compose logs backup` + `df` | phpbu failure, disk full, or the `glpi-backup` job not firing |

## GLPI / image version bumps

There are **two** version knobs and they mean different things:

- **`.glpi-version`** (currently `11.0.8`) is the GLPI release the image is
  *built from*. It feeds the `GLPI_VERSION` build arg; the image bundles that
  GLPI tarball (no Composer step at runtime). It only matters if you **build**
  the image yourself.
- **`GLPI_IMAGE_TAG`** (in `.env`) selects which *published* image tag the
  stack *runs*. Both the `app` and `app-assets` services use it.

Published tags follow the build workflow (`.github/workflows/_build-cell.yml`):

| Tag | Example | Mutable? |
|---|---|---|
| exact version | `11.0.8` | re-pushed on each daily rebuild |
| dated version | `11.0.8-20260628` | immutable — one build, never overwritten |
| floating minor / major | `11.0`, `11` | daily |
| floating latest | `latest` | daily |

The floating tags (`latest`, `11`, `11.0`, `11.0.8`) are **rebuilt daily** so
base-image (Alpine/PHP) CVE patches land without waiting for a GLPI release.
For reproducible production deployments, pin `GLPI_IMAGE_TAG` to a **dated**
tag and bump it deliberately; use `latest` only if you want automatic CVE
patching and accept that the base moves under you.

### Upgrade to a new published image (the common case)

```bash
# 1. pick the tag in .env
GLPI_IMAGE_TAG=11.0.9          # or a dated tag, e.g. 11.0.9-20260701

# 2. pull + recreate + follow the app log
make upgrade                   # = make pull && docker compose up -d && make logs-app
```

On boot the entrypoint detects the existing install and runs
`database:update` (maintenance-wrapped — see below). Watch the log for
`database:update complete`.

### Build a new bundled GLPI yourself

```bash
# 1. set the release + its tarball checksum (supply-chain pin)
echo 11.0.9 > .glpi-version
#    GLPI_SHA256 = sha256 of glpi-11.0.9.tgz from the GitHub release assets

# 2. build + structure-test the runtime image locally
make build
make test-image
```

Then publish via CI (push to `main` rebuilds the pinned release from
`.glpi-version`). Keep `.glpi-version` and the `GLPI_IMAGE_TAG` you deploy
coherent.

> GLPI schema migrations are **forward-only**. Running an *older* image against
> a database already migrated by a *newer* one produces schema errors. Roll
> forward, or restore the matching day's DB snapshot — see
> [runbook-restore.md](runbook-restore.md).

## Schema: the `database:update` flow

The entrypoint decides install-vs-upgrade by two facts: `config_db.php` exists
in `/etc/glpi` **and** the `glpi_configs` table exists in the DB.

- **Installed** → it wraps the upgrade in maintenance mode:
  `maintenance:enable` → `database:update` → `maintenance:disable`. The
  update's return code is captured and re-raised *after* maintenance is
  disabled, so a failed upgrade never leaves the instance wedged in
  maintenance, and a non-zero rc crashes the container (visible in
  `docker compose logs app`) rather than serving a half-migrated schema.
- **Not installed, `GLPI_AUTOINSTALL=true`** (default) → fresh
  `database:install` (creates the schema **and** a new `glpicrypt.key`).
- **Not installed, `GLPI_AUTOINSTALL=false`** → it does nothing and expects a
  manual setup. Use this when migrating data in (see
  [migration-from-upstream-single-container.md](migration-from-upstream-single-container.md))
  so a premature boot can't auto-reinstall over your data.

`SKIP_DB_UPDATE=true` skips the on-boot upgrade — for multi-replica setups
where you run the upgrade once, out of band:

```bash
docker compose exec -u www-data app php bin/console database:update --no-interaction
```

## Cache: Valkey wiring

The entrypoint points GLPI's `core` cache context at Valkey
(`redis://valkey:6379` by default, from `GLPI_CACHE_DSN`) and records the DSN
in a marker file (`/var/lib/glpi/files/_cache/.configured-dsn`) so it only
reconfigures when the DSN actually changes. If Valkey is unreachable it logs
the failure and GLPI falls back to the filesystem cache.

```bash
# reconfigure manually (e.g. after changing the DSN)
docker compose exec -u www-data app php bin/console cache:configure \
  --context=core --dsn=redis://valkey:6379 --no-interaction

# clear the cache (after a config change or odd UI state)
docker compose exec -u www-data app php bin/console cache:clear
```

### Valkey cache pressure

`compose.yml` runs Valkey with `--maxmemory 256mb --maxmemory-policy
allkeys-lru`. Under pressure, cache entries evict → cache misses → slower
pages and more DB load. **This does not log users out**: GLPI keeps sessions
as PHP files under `/var/lib/glpi/files/_sessions` on the `glpi-var` volume,
not in Valkey. If eviction is hurting performance, raise `--maxmemory` (and
the `valkey` `mem_limit`) in `compose.yml`.

## Cron: running `front/cron.php`

GLPI's task runner is `front/cron.php`. The `scheduler` (ofelia) execs it as
`www-data` inside `app` every 2 minutes via the `glpi-cron` label; once an
external cron calls it within GLPI's threshold, GLPI switches to CLI cron mode
and stops piggy-backing tasks onto page loads.

```bash
# run all due automatic actions now
docker compose exec -u www-data app php /var/www/glpi/front/cron.php
```

Manage individual automatic actions (frequency, mode, reset) in the UI under
**Setup > Automatic actions**.

A second ofelia job, `glpi-heartbeat`, touches
`/var/lib/glpi/files/.cron-heartbeat` every minute. The app healthcheck goes
**unhealthy** if that file falls more than 300 s behind — surfacing a dead
scheduler or a lost docker socket even when php-fpm itself is fine.

```bash
docker compose logs scheduler --tail=20     # expect "[Job \"glpi-cron\"] ... Finished"
docker compose exec app stat -c '%y' /var/lib/glpi/files/.cron-heartbeat
```

## Marketplace / plugins

Plugins live on the `glpi-plugins` volume, mounted at `/var/lib/glpi/plugins`
(the image's `GLPI_MARKETPLACE_DIR`). Because that is a writable volume — not
the read-only code root — both marketplace installs and manually-dropped
plugins persist across image bumps.

The in-UI marketplace (**Setup > Marketplace**) needs:

- outbound HTTPS from the `app` container to GLPI's marketplace API (set an
  HTTP proxy under **Setup > General > Proxy** if you egress through one), and
- write access to the `glpi-plugins` volume (it is read-write by default).

### Install a plugin by hand

```bash
# copy it onto the volume, then fix ownership
docker compose cp ./myplugin app:/var/lib/glpi/plugins/myplugin
docker compose exec app chown -R www-data:www-data /var/lib/glpi/plugins/myplugin
```

Then install + enable it under **Setup > Plugins** (a plugin's own DB schema is
created by that install action, not by `database:update`). The plugin console
commands are available too — `docker compose exec -u www-data app php
bin/console list | grep -i plugin` lists the exact names for your GLPI version.

## Logs — where to look

- **Container logs** (live, via the json-file driver with 10 MiB × 5
  rotation): `docker compose logs <service>`.
  - `app` — php-fpm worker stderr (the pool sets `catch_workers_output = yes`
    and `error_log = /proc/self/fd/2`), so PHP errors surface here live.
  - `web` — nginx access + error.
  - `db`, `valkey`, `scheduler` (ofelia job lines), `backup` (phpbu output).
- **GLPI application logs** on the `glpi-logs` volume at `/var/log/glpi`
  (the image's `GLPI_LOG_DIR`):

  ```bash
  docker compose exec app sh -c 'ls -la /var/log/glpi'
  docker compose exec app sh -c 'tail -n 50 /var/log/glpi/php-errors.log'
  ```

  Typical files: `php-errors.log`, `sql-errors.log`, `event.log`. Some
  components and older plugins still write under the files tree at
  `/var/lib/glpi/files/_log` (the `glpi-var` volume) — check there too if a log
  you expect isn't in `/var/log/glpi`.

## Tuning php-fpm and MariaDB

### php-fpm / PHP

The pool and PHP overrides are baked into the image from the repo:

- `rootfs/usr/local/etc/php-fpm.d/zz-glpi.conf` — `pm = dynamic`,
  `pm.max_children = 25`, `pm.max_requests = 500`, the unix-socket listener,
  and the `clear_env = yes` + explicit `env[...]` allow-list (the
  `GLPI_*_DIR` vars are load-bearing — GLPI reads them to locate config/files/
  plugins/logs outside the read-only code root).
- `rootfs/usr/local/etc/php/conf.d/glpi.ini` — `memory_limit = 512M`,
  `post_max_size` / `upload_max_filesize = 64M`, `max_input_vars = 5000`,
  OPcache with `validate_timestamps = 0` (the code layer is immutable, so a new
  image is the only way to invalidate it).

To change these, either edit the file and **rebuild**, or bind-mount an
override over the path via `compose.override.yml` (no rebuild):

```yaml
# compose.override.yml
services:
  app:
    volumes:
      - ./my-glpi.ini:/usr/local/etc/php/conf.d/zz-override.ini:ro
```

Sizing: `app.mem_limit` (default `1.5g`) has to cover concurrency —
worst-case `pm.max_children * memory_limit` (25 × 512M), though real RSS is far
lower. Raise `pm.max_children` **and** `app.mem_limit` together for more
concurrency. To accept larger uploads, raise `post_max_size` +
`upload_max_filesize` in `glpi.ini` **and** `client_max_body_size` in
`config/nginx/conf.d/default.conf` (currently `64M`) — the smaller of the two
wins.

### MariaDB

Tuning lives in the `db` service `command:` list in `compose.yml` (charset,
`READ-COMMITTED` isolation, binlog, and the durability pair `--sync_binlog=1`
+ `--innodb_flush_log_at_trx_commit=1`). Add flags there (or mount a
`my.cnf`) for deeper tuning, e.g. `--innodb_buffer_pool_size`. Raise
`db.mem_limit` (default `2g`) as the dataset grows and size the buffer pool to
~50-70 % of it.

> The durability pair is **required for honest point-in-time recovery** — every
> committed transaction is fsync'd before the client sees the ACK. Only relax
> it (to `0`/`2`) if you pair the host with a UPS / battery-backed cache.

## The ofelia "docker socket is host-wide" gotcha

The `scheduler` service mounts the host `/var/run/docker.sock` (read-only) and
drives jobs by reading `ofelia.*` labels off containers **through that
socket**. The socket is **host-wide**, so ofelia discovers and execs jobs in
*every* container on the host that carries `ofelia.enabled=true` +
`ofelia.job-exec.*` labels — not just this stack's `app` and `backup`.

Consequences and mitigations:

- Run **two** ofelia daemons on one host (this stack plus another Compose
  project that also ships ofelia) and **both** will try to run **both** stacks'
  labelled jobs → `cron.php` and the backup fire twice. Run **one** ofelia per
  host, or scope each daemon with a docker label filter.
- A container from an unrelated project that reuses a job name can collide.
  Keep job names unique across the whole host — this stack namespaces them
  (`glpi-cron`, `glpi-heartbeat`, `glpi-backup`).
- **Security:** mounting the docker socket — even read-only — is effectively
  root on the host (you can exec into any container and reach the host
  filesystem). Treat `scheduler` as a privileged component, don't expose it,
  and keep `ghcr.io/netresearch/ofelia` current.

If ofelia can't reach the socket (SELinux, rootless/podman socket path), the
container exits immediately and `docker compose logs scheduler` says so. A
silent-but-alive scheduler is caught by the app heartbeat healthcheck above.

```bash
docker compose restart scheduler app     # recreate the label-watching loop
```

## Failure modes

### Poisoned DB volume (empty `DB_ROOT_PASSWORD`)

**Cause:** `docker compose up` ran without `make init` (or `.env` lacked
`DB_ROOT_PASSWORD`). MariaDB initialised the data volume with an empty root
password and persists it; later `make init && make up` can't authenticate.

**Fix (no data to keep):**

```bash
docker compose down
docker volume rm glpi-db-data        # destroys the DB
make init                            # fresh passwords
make up
```

If the poisoned volume holds data you need, exec a one-shot `mariadb` against
the same volume to set the password before bringing the stack up.

### Schema upgrade failed (app exits / 500 after a bump)

`docker compose logs app` shows the `database:update` error and `ERROR:
database:update failed`. The container exits on purpose. Read the migration
error, fix the cause (most often a DB-permission gap on a new release — the
GLPI user already has `ALTER` here), then `docker compose up -d` to retry.
Because the upgrade is maintenance-wrapped, the instance is not left stuck in
maintenance.

### Daily rebuild produced a broken floating tag

A floating tag (`latest`/`11`/`11.0`/`11.0.8`) pulled today is broken. Roll
back to the last-good **dated, immutable** tag:

```bash
# 1. list dated tags (needs `crane`, or use the ghcr.io package UI)
crane ls ghcr.io/netresearch/glpi-php-fpm | grep -E '^11\.0\.8-[0-9]{8}$' | sort -r | head
# 2. pin it
echo 'GLPI_IMAGE_TAG=11.0.8-20260520' >> .env
# 3. re-up (both app and app-assets follow GLPI_IMAGE_TAG)
docker compose pull
docker compose up -d
docker compose logs -f --tail=50 app
```

Then file a bug against `netresearch/glpi-docker-compose-stack`.

## Maintenance windows

The nightly phpbu backup fires at **03:00 UTC**: the `scheduler` service sets
no `TZ`, so ofelia evaluates its `0 0 3 * * *` schedule in UTC regardless of
the stack-wide `TZ` in `.env`. (The interval jobs `glpi-cron`/`glpi-heartbeat`
are `@every`-based, so timezone is irrelevant to them.) Schedule disruptive
maintenance away from 03:00 UTC, and take an on-demand snapshot before a risky
change:

```bash
make backup            # runs phpbu now
make backup-list       # what's on disk
make backup-verify     # confirms last night's dump exists + is non-zero
make health            # aggregated health of every service
```

## Service / volume map

| Service | Image | Role |
|---|---|---|
| `db` | `mariadb:11` | database, binlog enabled (PITR-ready) |
| `valkey` | `valkey/valkey:9-alpine` | GLPI `core` cache |
| `app-assets` | `glpi-php-fpm` | one-shot: syncs `public/` into the web volume |
| `app` | `ghcr.io/netresearch/glpi-php-fpm` | php-fpm + GLPI code |
| `web` | `nginx:alpine` | serves `public/` statics + FastCGI to `app` |
| `scheduler` | `ghcr.io/netresearch/ofelia` | label-driven cron (`glpi-cron`, `glpi-heartbeat`, `glpi-backup`) |
| `backup` | `ghcr.io/netresearch/phpbu-docker` | nightly DB + files + config archives |

| Volume | Mount | Holds |
|---|---|---|
| `glpi-config` | `/etc/glpi` | `config_db.php` + **`glpicrypt.key`** + local config |
| `glpi-var` | `/var/lib/glpi/files` | uploads, sessions, cache, dumps, inventories |
| `glpi-plugins` | `/var/lib/glpi/plugins` | marketplace + manual plugins |
| `glpi-logs` | `/var/log/glpi` | GLPI application logs |
| `glpi-db-data` | `/var/lib/mysql` | MariaDB data + binlogs |
| `glpi-valkey-data` | `/data` | Valkey AOF |
| `glpi-backups` | `/backups` | phpbu artefacts |

For disaster recovery from these artefacts, see
[runbook-restore.md](runbook-restore.md).
