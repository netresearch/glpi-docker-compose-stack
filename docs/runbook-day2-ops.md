<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- Copyright (c) 2026 Netresearch DTT GmbH -->

# Runbook — Day-2 operations

Day-2 = "after `make up` works, before the first 3 AM incident".
This file catalogues the failure modes we know about, what to look for,
and how to recover. Borrows the gap-matrix structure from review #11.

## Quick reference

| Symptom | First check | Likely cause |
|---|---|---|
| App returns 500 | `make logs-app` | Migration failure or PHP fatal — Laravel error now in stdout (LOG_CHANNEL=stderr) |
| Login loops back to /login | `make logs-app` for `Session` | Cookie not arriving / TLS mismatch — see "APP_URL ≠ public URL" below |
| `docker compose up` won't start | `make ps` + `docker compose logs` | DB volume initialised with wrong password (see "Poisoned DB volume" below) |
| Browser shows 502 right after `make up` | wait 60-90 s | App still doing `php artisan migrate --force` on first start |
| `phpbu` errors in `/backups/phpbu.log` | check disk free | Backup volume capacity, DB unreachable, or `MARIADB_ROOT_PASSWORD` mismatch |
| Users randomly logged out | check Valkey memory | LRU eviction kicked in — see "Valkey cache pressure" below |
| Scheduler tasks not running | `docker compose logs scheduler` | ofelia can't reach docker socket / label drift |

## Failure modes

### Poisoned DB volume (empty MARIADB_ROOT_PASSWORD)

**Cause:** `make up` ran without `make init` (or `.env` didn't have
`DB_ROOT_PASSWORD`). MariaDB initialised the data volume with an empty
root password and persists it. Subsequent `make init && make up` can't
authenticate.

**Fix:** the `.env`-presence guard in the Makefile catches this for
fresh installs, but for already-poisoned volumes:

```bash
docker compose down
docker volume rm glpi-db-data   # ⚠ destroys the DB
make init                          # generates fresh passwords
make up
```

If you DO have data in the poisoned DB you need to keep, exec a one-shot
mariadb container against the same volume to set a password before
running the stack, then `make up`.

### App returns 500 / 502

1. `make logs-app` — Laravel errors now go to container stdout as JSON
2. Common cases:
   - **Migration failure** — usually because the DB user doesn't have a
     permission required by a new release. GLPI migrations require
     `ALTER`; our DB user already has it.
   - **APP_KEY missing / regenerated** — encrypted columns can't be
     decrypted. Restore the original `.env` or restore the DB from
     before the rotation.
   - **Storage volume permission** — entrypoint repairs `www-data`
     ownership on every start, but a host-side `chown` could break this.
     Check `docker compose exec app ls -ld /var/www/html/storage`.

### Login loops / users can't log in

Usually one of three:

- **APP_URL ≠ the URL the user actually hits.** GLPI generates the
  CSRF cookie scoped to APP_URL. If your reverse proxy serves
  `https://glpi.example.com` but `APP_URL=http://localhost:8000`,
  the cookie never makes it back. Fix: update `APP_URL` in `.env`,
  `make restart`.
- **Cookie not flagged secure but served over HTTPS** — happens when
  `SECURE_COOKIES=false` (our default is `true`). If you're
  serving plain HTTP in dev, set `SECURE_COOKIES=false` in
  `compose.override.yml`.
- **Valkey lost the session.** See cache pressure below.

### Valkey cache pressure / silent re-logins

**Cause:** `compose.yml` configures Valkey with `--maxmemory 256mb
--maxmemory-policy allkeys-lru`. Under load — especially with
`SESSION_DRIVER=redis` — old sessions get evicted; users have to log in
again. This is generally fine for ad-hoc users but disruptive for kiosks
or always-logged-in dashboards.

**Mitigations:**

- Increase `--maxmemory` in `compose.yml` (e.g. `512mb` or `1g`)
- Or split: keep `CACHE_DRIVER=redis`, set `SESSION_DRIVER=file` so
  sessions survive cache pressure (cost: sticky sessions impossible
  across replicas, but this stack is single-replica)
- Or use `volatile-lru` so only keys with explicit TTL evict — but
  GLPI doesn't TTL its sessions by default

### Backup volume full / phpbu silent failures

**Detect:**

```bash
make backup-verify      # checks newest dump < 26 h old, non-zero bytes
make backup-list        # shows current usage
docker compose exec backup df -h /backups
```

**Fix:**

- If retention rules aren't keeping up, drop the capacity in
  `config/phpbu/backup.json`:
  - `cleanup.options.size` on the DB target (currently `5G`)
  - `cleanup.options.older` on uploads/storage (currently `30D`)
- Or bind-mount `backups:/backups` to a larger host directory
- If phpbu is being killed mid-run (OOM, network hiccup), check
  `docker compose logs backup` for the exit status

### Scheduler tasks not running

**Cause:** ofelia drives `artisan schedule:run` per minute via the
`ofelia.job-exec.*` labels on the `app` container. If ofelia can't reach
the docker socket, or the app container's labels drift after a manual
`docker run`, the schedule silently stops.

**Detect:**

```bash
docker compose logs scheduler --tail=20
# Expect lines like:
#   [Job glpi-schedule] Started ...
#   [Job glpi-schedule] Finished in X ms
```

**Fix:**

```bash
docker compose restart scheduler app
# Recreates the label-watching loop and the app container.
```

If the docker socket is missing (selinux, podman, rootless mismatch),
the scheduler container will exit immediately — `docker compose logs
scheduler` will say so.

### Daily rebuild produced a broken `latest`

**Detect:**

```bash
# A user reports breakage on the most-recent pull
docker compose pull   # but it pulled the broken image
docker compose up -d
docker compose logs -f --tail=50 app
```

**Rollback to a known-good dated tag:**

```bash
# 1. Identify the previous-good dated tag from ghcr.io UI or:
crane ls ghcr.io/netresearch/glpi-php-fpm | grep -E '^8\.5\.0-[0-9]{8}$' | sort -r | head -10
# 2. Set in .env:
echo 'GLPI_IMAGE_TAG=8.5.0-20260520' >> .env
# 3. Re-up:
docker compose pull
docker compose up -d
```

Forward: file a bug against `netresearch/glpi-docker-compose-stack`
(this repo) so we can investigate and patch.

## Observability — what's available, what to add

The stack ships with healthchecks on every service but no metrics
endpoint. `make health` aggregates the current health state of all
containers — wire it into your existing monitoring (Nagios, Zabbix,
Prometheus blackbox_exporter, etc.).

For Prometheus-shape metrics, add `php-fpm-exporter` and
`nginx-prometheus-exporter` as compose-overlay sidecars. Not yet a
shipped example — see [#TODO] for a `compose.prometheus.yml`.

For log aggregation, the stack writes everything to container stdout:

- `db`: mariadbd query log on stderr
- `valkey`: redis log on stdout
- `app`: Laravel JSON via `LOG_CHANNEL=stderr` + php-fpm worker output
- `web`: nginx access + error log on stdout/stderr
- `scheduler`: ofelia job-execution lines on stdout
- `backup`: phpbu run output (also written to `/backups/phpbu.log`)

Wire a Loki / Vector / Filebeat agent to scrape `docker logs` and you
have a working aggregator without changing the stack.

## Maintenance windows

The scheduler runs Laravel `schedule:run` every minute and `phpbu` at
03:00 UTC. Plan maintenance for 02:00-03:00 UTC to avoid colliding with
the backup window. `make backup` on-demand if you want a snapshot
immediately before a planned change.
