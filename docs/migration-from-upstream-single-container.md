<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- Copyright (c) 2026 Netresearch DTT GmbH -->

# Migration: from the official `glpi/glpi` single-container image to this stack

You run GLPI on the official `glpi/glpi` image — Apache + mod_php (plus an
in-container cron worker) in one container, with all GLPI state under a single
`/var/glpi` data volume — and you want to move to this php-fpm + nginx split
stack without losing data and without an open-ended downtime window. This
guide does that as an experienced operator would: snapshot what you have,
prepare the new home on the side, then a short cutover with a clean rollback
path. Allow about 30 minutes; the cutover itself runs in roughly 10.

## What's actually changing

| Concern | Official `glpi/glpi` | This stack |
|---|---|---|
| Web server | Apache + mod_php (in-container) | nginx (`web`) + php-fpm (`app`) |
| Cron | in-container worker (`GLPI_CRONTAB_ENABLED`) | `scheduler` (ofelia) → `front/cron.php` every 2 min |
| Cache | filesystem default | `valkey` (RESP-compatible Redis fork) |
| Data layout | one volume at `/var/glpi` | split named volumes (table below) |
| Database | bring-your-own / sibling container | `db` (MariaDB 11) — BYO DB also supported |
| Backups | external | `backup` (phpbu) — nightly DB + files + config |

The PHP-FPM image bundles the GLPI release tarball (no Composer step at
runtime), is multi-arch (`amd64` + `arm64`), and rebuilds nightly so base-OS
CVE patches land without waiting for a GLPI release. The other services use
upstream images.

### The path mapping (the crux)

The official image consolidates everything under `/var/glpi`; this stack
splits it across purpose-built volumes:

| Official path | Holds | Goes into this stack's |
|---|---|---|
| `/var/glpi/config` | `config_db.php` + **`glpicrypt.key`** + local config | `glpi-config` volume → `/etc/glpi` |
| `/var/glpi/files` | uploads, pictures, inventories, dumps, sessions, cache | `glpi-var` volume → `/var/lib/glpi/files` |
| `/var/glpi/marketplace` | marketplace-installed plugins | `glpi-plugins` volume → `/var/lib/glpi/plugins` |
| `/var/glpi/logs` | application logs (regenerated; optional to migrate) | `glpi-logs` volume → `/var/log/glpi` |
| `/var/www/glpi/plugins` | manually-dropped plugins, if you used them | `glpi-plugins` volume → `/var/lib/glpi/plugins` |

> The official image's install/skip flags are `GLPI_SKIP_AUTOINSTALL` /
> `GLPI_SKIP_AUTOUPDATE`. This stack's equivalents are named differently —
> `GLPI_AUTOINSTALL` (default `true`) and `SKIP_DB_UPDATE` — so don't copy the
> old variable names across.

## Read this first: `glpicrypt.key` must travel with the database

`/var/glpi/config/glpicrypt.key` is GLPI's AES key for every encrypted DB
field — LDAP/AD bind passwords, mail-collector credentials, external-DB and
API secrets, plugin secrets. It **must** move together with the database. A
new stack that doesn't get the original key (or worse, generates a fresh one)
renders every stored credential unreadable: the UI loads, rows exist, but the
content is garbage and must be re-entered.

This stack's entrypoint will **not** generate a new key when a DB config is
present but the key is missing — it warns and refuses — but the safe move is to
copy `/var/glpi/config` wholesale so the key comes along.

## Before you start

**Know your source GLPI version.** This stack's image runs `database:update`
on boot, applying GLPI's sequential migrations from your database's recorded
version up to the image's version (currently 11.0.8). From a recent 10.0.x or
11.0.x source this is supported. **⚠️ assumed for *your* specific source:** if
you're on a much older release, upgrade the legacy instance to the latest
10.0.x first to keep the jump inside a supported migration path — confirm
against GLPI's upgrade documentation before committing to downtime.

**Inventory the old volume.** Identify the single `/var/glpi` data volume (and
any separate `/var/www/glpi/plugins` mount):

```bash
docker volume ls
docker inspect <old-glpi-container> --format '{{json .Mounts}}' | tr ',' '\n'
```

**Plan the proxy.** External reverse proxies just need to point at this stack's
`web` service (loopback `GLPI_HTTP_PORT`, or attach the proxy to the `glpi`
network); in-Compose proxies attach their network to `web` via
`compose.override.yml`. See `examples/compose.traefik.yml`.

A few shell variables make the rest readable:

```bash
export LEGACY_DIR=/srv/www/glpi-old           # current single-container stack
export DEPLOY_DIR=/srv/www/glpi               # where this stack will live
export BACKUP_DIR=/srv/backup/glpi-migration
export OLD_DATA_VOLUME=glpi_data              # the real /var/glpi volume name
mkdir -p "$BACKUP_DIR"
```

## Snapshot while the lights are still on

This runs against the running legacy stack — no downtime yet.

```bash
# 1. Database dump. Run it wherever your DB actually lives. If the database is
#    a sibling MariaDB/MySQL container, dump from there (adjust the service
#    name + root credential). For an external/managed DB, run mysqldump from a
#    host that can reach it.
docker compose -f "$LEGACY_DIR/docker-compose.yml" exec -T db sh -c '
  mariadb-dump --single-transaction --quick \
    -uroot -p"$MARIADB_ROOT_PASSWORD" "$MARIADB_DATABASE"
' | gzip > "$BACKUP_DIR/glpi-db.sql.gz"

# 2. The whole /var/glpi tree (config incl. glpicrypt.key, files, marketplace,
#    logs). Read it straight off the volume with a throwaway container so you
#    don't depend on tools inside the glpi image.
docker run --rm \
  -v "$OLD_DATA_VOLUME":/var/glpi:ro \
  -v "$BACKUP_DIR":/backup \
  alpine tar czf /backup/glpi-data.tar.gz -C /var/glpi .
```

Sanity-check both artefacts are non-empty before you burn any downtime:

```bash
ls -lah "$BACKUP_DIR"
```

If either looks suspiciously small, stop and investigate — you don't want to
discover an empty dump on the far side of downtime.

## Stand up the new stack (stopped)

```bash
git clone https://github.com/netresearch/glpi-docker-compose-stack.git "$DEPLOY_DIR"
cd "$DEPLOY_DIR"
make init          # generates .env with fresh random DB passwords
```

Edit `.env`. The values that matter for a migration:

- **`GLPI_AUTOINSTALL=false`** — **critical.** It stops the entrypoint from
  running a fresh `database:install` (which would create an empty schema *and*
  a new `glpicrypt.key`) if `app` boots before your data is in place. With the
  DB + config restored, the entrypoint detects the existing install and runs
  `database:update` instead.
- `TZ`, `GLPI_HTTP_PORT`, `GLPI_HOST` — set to taste.
- There is **no `APP_KEY`** here — GLPI's encryption key is the
  `glpicrypt.key` *file* you're migrating, not an env var.

Leave the `make init` DB passwords as they are; we adopt the bundled `db`
service and rewrite the restored `config_db.php` to match it during cutover.
(Alternative: to reuse your existing external DB, point `GLPI_DB_HOST` at it,
remove/replace the bundled `db` service in `compose.override.yml`, and keep the
old `config_db.php` host unchanged.)

Do **not** `docker compose up` yet — that happens during cutover, with the old
stack already stopped, so two stacks never race the same hostname.

## The cutover

Work straight through; this is the dark stretch.

```bash
# 1. Old stack down — downtime starts here.
docker compose -f "$LEGACY_DIR/docker-compose.yml" down

# 2. Bring up ONLY db + valkey on the new stack so the restore has a target.
cd "$DEPLOY_DIR"
docker compose up -d db valkey
docker compose exec -T db sh -c '
  until mariadb-admin ping -uroot -p"$MARIADB_ROOT_PASSWORD" --silent; do sleep 1; done'

# 3. Restore the DB dump into the new db (the dump is a single named database).
zcat "$BACKUP_DIR/glpi-db.sql.gz" \
  | docker compose exec -T db sh -c 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" "$MARIADB_DATABASE"'
```

Now unpack `/var/glpi` once into a staging directory and load each subtree into
its matching named volume. Staging first keeps the mapping explicit and avoids
fragile in-tar path surgery:

```bash
# 4. Unpack the snapshot
mkdir -p "$BACKUP_DIR/stage"
tar xzf "$BACKUP_DIR/glpi-data.tar.gz" -C "$BACKUP_DIR/stage"
ls "$BACKUP_DIR/stage"        # -> config  files  logs  marketplace

# config (config_db.php + glpicrypt.key + local config) -> glpi-config
docker run --rm -v glpi-config:/dest -v "$BACKUP_DIR/stage/config":/src:ro \
  alpine sh -c 'cp -a /src/. /dest/'

# files -> glpi-var
docker run --rm -v glpi-var:/dest -v "$BACKUP_DIR/stage/files":/src:ro \
  alpine sh -c 'cp -a /src/. /dest/'

# marketplace plugins -> glpi-plugins (skip if your source had none)
docker run --rm -v glpi-plugins:/dest -v "$BACKUP_DIR/stage":/stage:ro \
  alpine sh -c '[ -d /stage/marketplace ] && cp -a /stage/marketplace/. /dest/ || echo "no marketplace dir — skipping"'
```

Fix ownership on the migrated trees using the **app image's own** `www-data`
(so the uid is correct regardless of base-image differences), then rewrite the
DB connection settings to point at the new `db` service — without touching the
schema or the key:

```bash
# 5. Deep-chown the migrated state to the runtime user
docker compose run --rm --user root --entrypoint sh app -c '
  chown -R www-data:www-data /etc/glpi /var/lib/glpi/files /var/lib/glpi/plugins'

# 6. Repoint config_db.php at the bundled db (writes only config_db.php;
#    never drops/installs the schema, never touches glpicrypt.key)
docker compose run --rm --user www-data --entrypoint sh app -c '
  php bin/console database:configure --reconfigure \
    --db-host=db --db-port=3306 \
    --db-name="$GLPI_DB_NAME" --db-user="$GLPI_DB_USER" \
    --db-password="$GLPI_DB_PASSWORD" --no-interaction'
```

Bring everything up and let the schema migrate:

```bash
# 7. Full start — the entrypoint sees config_db.php + the glpi_configs table
#    and runs database:update (NOT a fresh install, because data is present and
#    GLPI_AUTOINSTALL=false).
docker compose up -d
docker compose logs -f app
```

Watch for `database:update complete` and confirm the entrypoint does **not**
print the `glpicrypt.key MISSING` warning.

## How you know it worked

Test the canary first: log in, open **Setup > Authentication > LDAP
directories**, and run **Test** on a directory. A successful bind proves
`glpicrypt.key` migrated correctly — the encrypted bind password decrypts. If
it fails, the key did not transfer; stop and fix it before anyone relies on the
instance.

Then walk the rest:

```bash
docker compose ps                                           # every service healthy
curl -fsS -I "http://127.0.0.1:${GLPI_HTTP_PORT:-8080}/" | head -5
docker compose logs scheduler --tail=20                     # glpi-cron firing within ~2 min
docker compose exec app stat -c '%y' /var/lib/glpi/files/.cron-heartbeat   # fresh
```

Click around for a couple of minutes watching `docker compose logs -f app` —
no stack traces, no decryption warnings, no 500s.

## If something goes wrong

The new stack only wrote to its own volumes during cutover, so rollback is
fast:

```bash
cd "$DEPLOY_DIR" && docker compose down
docker compose -f "$LEGACY_DIR/docker-compose.yml" up -d
```

The snapshot in `$BACKUP_DIR` is your worst-case insurance.

**Stored credentials look empty / "decryption failed".** `glpicrypt.key` didn't
migrate, or a fresh one was generated. Check it's there and the entrypoint
didn't warn:

```bash
docker run --rm -v glpi-config:/c:ro alpine ls -l /c/glpicrypt.key
docker compose logs app | grep -i glpicrypt
```

Re-run step 4's config copy from the snapshot, `chown` (step 5), restart.

**App can't connect to the database.** `config_db.php` still points at the old
host/credentials — re-run step 6 (`database:configure --reconfigure`).

**Reverse proxy returns 502.** The proxy is still targeting the old container
or network. Point it at the new `web` service, or attach `web` to the proxy's
network. This stack's own network is named `glpi`.

**Scheduler logs say permission denied on the docker socket.** ofelia needs the
host's `/var/run/docker.sock` to exec `front/cron.php` into `app`. Check the
`scheduler` service's volume mount against the real socket path (rootless /
podman setups expose it elsewhere).

## After the dust settles

Give the new stack a day or two of normal traffic and let one nightly `phpbu`
run finish (03:00 UTC — the scheduler evaluates its cron in UTC) so you've proven the
backup loop end-to-end — note that this stack now archives the config dir
(including `glpicrypt.key`) for you. Then archive the legacy directory rather
than deleting:

```bash
mv "$LEGACY_DIR" "${LEGACY_DIR}.archive-$(date +%Y%m%d)"
```

Keep the migration snapshot in `$BACKUP_DIR` for ~30 days; after that the
stack's nightly phpbu artefacts cover you.

## Staying current

For routine updates afterward, see
[runbook-day2-ops.md](runbook-day2-ops.md) (version bumps via `GLPI_IMAGE_TAG`
/ `.glpi-version`, the daily-rebuild tag scheme, and the `database:update`
flow). For disaster recovery from phpbu artefacts, see
[runbook-restore.md](runbook-restore.md).
