<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- Copyright (c) 2026 Netresearch DTT GmbH -->

# Runbook — Restore from backup

The canonical recovery procedure when this stack's database, uploaded files,
or configuration is lost, corrupted, or needs rolling back to a known-good
snapshot. Backups are produced nightly by the `backup` service (phpbu); the
job is defined in `config/phpbu/backup.json` and fires at **03:00 UTC** (the
`scheduler` service sets no `TZ`, so ofelia evaluates `0 0 3 * * *` in UTC).

## Read this first: `glpicrypt.key`

`glpicrypt.key` lives on the **`glpi-config`** volume (`/etc/glpi`) and is
GLPI's AES key for **every encrypted database field** — LDAP/AD bind
passwords, mail-collector passwords, external-DB and API credentials, and
plugin secrets. It is created once at install and never rotates.

Restoring the database **without** the matching key leaves all of those fields
as undecryptable ciphertext. GLPI keeps running and the rows still exist, but
every stored credential is unusable and must be re-entered by hand. There is no
command to "re-derive" the plaintext — the key *is* the secret.

This is why `backup.json` archives the config directory (kept 90 days, longer
than the others), and why the entrypoint **refuses to mint a new key** when
`config_db.php` is present but the key is missing — it warns loudly instead, so
a "successful" DB restore can't silently become an unreadable one. **A DB
restore is only complete with the config archive from the same era.**

## Backup artefacts

Stored on the `glpi-backups` volume (mounted at `/backups` in the `backup`
container), in three subdirectories:

| Path | What | Cadence | Retention |
|---|---|---|---|
| `/backups/db/glpi-db-*.sql.gz` | `mysqldump --single-transaction --quick` of the GLPI database, gzip'd. Taken with `--databases`, so the dump is self-contained (`CREATE DATABASE IF NOT EXISTS` + `USE`) and includes `DROP TABLE IF EXISTS` per table | nightly 03:00 | capacity 5 GiB (oldest dropped) |
| `/backups/files/glpi-files-*.tar.gz` | tar of the `glpi-var` volume (`/var/lib/glpi/files`: uploads, pictures, inventories, dumps, sessions, cache) | nightly 03:00 | outdated 30 days |
| `/backups/config/glpi-config-*.tar.gz` | tar of the `glpi-config` volume (`/etc/glpi`: `config_db.php` + **`glpicrypt.key`** + local config) | nightly 03:00 | outdated 90 days |
| `/backups/phpbu.log` | JSON log of every phpbu run (success and failure) | per-run append | by phpbu |

Both tar artefacts are created by phpbu from the absolute paths `/snapshot/files`
and `/snapshot/config` (the volumes are mounted there read-only). GNU tar
strips the leading `/`, so the archives store entries as `snapshot/files/...`
and `snapshot/config/...` — hence the `--strip-components=2` in the restore
commands below.

```bash
make backup-list        # or:
docker run --rm -v glpi-backups:/b:ro alpine sh -c 'ls -la /b/db /b/files /b/config'
```

Pick a timestamp and pin it for the rest of the procedure:

```bash
export TS=20260627-030001        # the YYYYMMDD-HHMMSS in the filenames you chose
```

## Full restore (DB + files + config)

### 1. Quiesce the app tier

```bash
docker compose stop app web scheduler
# Leave db, valkey and backup up: we restore *into* db and read dumps via backup.
```

### 2. Restore the database

The dump is self-contained, so importing it drops + recreates every table it
contains:

```bash
docker compose exec -T backup sh -c "zcat /backups/db/glpi-db-${TS}.sql.gz" \
  | docker compose exec -T db sh -c 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD"'
```

For a guaranteed-pristine restore (drops tables that exist now but weren't in
the dump), drop the database first, then import:

```bash
docker compose exec -T db sh -c '
  mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "
    DROP DATABASE IF EXISTS \`$MARIADB_DATABASE\`;
    CREATE DATABASE \`$MARIADB_DATABASE\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"'
# then run the import above ($MARIADB_DATABASE is set inside the db container)
```

A large dump can take minutes — let it finish.

### 3. Restore the files volume (`glpi-var`)

The app is stopped, so nothing is writing the volume. Use a throwaway
container that mounts the target volume read-write and the backups read-only:

```bash
docker run --rm -e TS="$TS" \
  -v glpi-backups:/backups:ro \
  -v glpi-var:/restore \
  alpine sh -c '
    cd /restore
    rm -rf ./* ./.[!.]* 2>/dev/null || true
    tar xzf "/backups/files/glpi-files-${TS}.tar.gz" --strip-components=2'
```

### 4. Restore the config volume (`glpi-config`) — the encryption key

Same pattern, but into `glpi-config`. **This is the step that re-instates
`glpicrypt.key`.**

```bash
docker run --rm -e TS="$TS" \
  -v glpi-backups:/backups:ro \
  -v glpi-config:/restore \
  alpine sh -c '
    cd /restore
    rm -rf ./* ./.[!.]* 2>/dev/null || true
    tar xzf "/backups/config/glpi-config-${TS}.tar.gz" --strip-components=2'

# confirm both files are present
docker run --rm -v glpi-config:/c:ro alpine ls -l /c/config_db.php /c/glpicrypt.key
```

> **Credential consistency:** the restored `config_db.php` carries the DB host
> and credentials from when the backup was taken. If you are restoring into a
> *fresh* stack whose `db` was initialised with different `make init`
> passwords, the app won't be able to connect. Either keep the original
> `GLPI_DB_*` values in `.env`, or rewrite the connection settings without
> touching the schema:
> ```bash
> docker compose run --rm --user www-data --entrypoint sh app -c '
>   php bin/console database:configure --reconfigure \
>     --db-host=db --db-port=3306 \
>     --db-name="$GLPI_DB_NAME" --db-user="$GLPI_DB_USER" \
>     --db-password="$GLPI_DB_PASSWORD" --no-interaction'
> ```
> `database:configure` only writes `config_db.php`; it never drops or installs
> the schema, and it leaves `glpicrypt.key` alone.

### 5. Bring the stack back up

```bash
docker compose up -d
docker compose logs -f app
```

The entrypoint sees the restored `config_db.php` + the `glpi_configs` table and
runs `database:update` (bringing the restored schema up to the image's GLPI
version). It must **not** print the `glpicrypt.key MISSING` warning — if it
does, step 4 didn't land.

### 6. Clear cache and verify

```bash
# Valkey may hold stale entries from before the restore
docker compose exec -u www-data app php bin/console cache:clear

docker compose ps                                   # every service healthy
curl -sI "http://127.0.0.1:${GLPI_HTTP_PORT:-8080}/" | head -1
```

Then log in and **test a stored credential** — e.g. an LDAP/AD directory
connection under **Setup > Authentication > LDAP directories**. A successful
bind proves `glpicrypt.key` was restored correctly; a failure means the key
didn't match the data.

## Database-only restore

For "undo a bad bulk change" incidents: do steps 1, 2, 5, 6 and skip the file
and config restores. The app keeps its current files + key.

Caveat: files referenced by the restored DB that were **deleted later** become
missing (404s), and files **added after** the snapshot become orphans the DB
no longer references. For point-in-time fidelity, restore all three.

## Config-only restore (re-instate a lost key)

If the database is intact but `glpicrypt.key` went missing (the `glpi-config`
volume was wiped), restore **only** the config archive from the same era as the
data — step 4, then `docker compose restart app`. Without the original key
there is no way to recover the encrypted fields; you would have to re-enter
every stored credential by hand.

## Point-in-time recovery via binlog (advanced)

The `db` service runs with `--log-bin=mariadb-bin --binlog-format=ROW
--binlog_expire_logs_seconds=1209600` (14 days) and `--sync_binlog=1`, so PITR
within the last 14 days is possible. Binlogs live at
`/var/lib/mysql/mariadb-bin.*` on the `glpi-db-data` volume.

> The phpbu dump uses `--single-transaction --quick` (not `--source-data`), so
> it does **not** embed a binlog coordinate. Replay is therefore anchored by
> **timestamp** just after the dump, not by exact position — accept a small
> imprecision around the dump boundary and verify row counts afterward.
>
> `mariadb-binlog` interprets `--start/--stop-datetime` in the **`db`
> container's** timezone (set from `TZ` in `.env`), which is *not* the 03:00
> **UTC** the dump was triggered at. Don't assume "03:xx" — read the dump's
> actual completion time from `/backups/phpbu.log` (or the dump file's mtime)
> and express your window in that same timezone.

```bash
# 1. Restore the dump taken BEFORE the bad event (steps 1-2 above).
# 2. Replay binlog events from just after that dump up to just before the event.
#    Substitute the real datetimes (db-container timezone) for the placeholders:
docker compose exec -T db sh -c '
  mariadb-binlog --database="$MARIADB_DATABASE" \
    --start-datetime="2026-06-27 05:01:00" \
    --stop-datetime="2026-06-27 14:29:59" \
    /var/lib/mysql/mariadb-bin.* \
  | mariadb -uroot -p"$MARIADB_ROOT_PASSWORD"'
```

`--start-datetime` ≈ just after the dump finished; `--stop-datetime` = the
instant before the bad event. `--database` filters to the GLPI database
(reliable with ROW format). Narrow the window iteratively if needed.

## Rollback to a previous image tag

If the problem is a broken image, not lost data, pin a previous **dated,
immutable** tag instead of restoring data:

```bash
# .env: GLPI_IMAGE_TAG=11.0.8-20260520
docker compose pull
docker compose up -d
```

GLPI migrations are **forward-only**: don't put an *older* image on a database
already migrated by a *newer* one — that errors. In that case do a full DB +
image restore from the matching day. See
[runbook-day2-ops.md](runbook-day2-ops.md) for the tag scheme.

## Verifying the backup pipeline

```bash
make backup-verify     # last night's dump is on disk and non-zero — does NOT restore
```

`backup-verify` proves the pipeline *ran*; it does not prove the artefacts are
*restorable*. Periodically run a real restore drill into a throwaway stack — a
backup you have never restored is a hypothesis, not a backup.

## Off-host shipping

`glpi-backups` is a local Docker volume: it survives container restarts but not
host loss. For real disaster recovery, push the artefacts off-host — and pay
special attention to the **config** archive, which holds `glpicrypt.key`:
losing it means losing every encrypted field even if the DB survives.

Either bind-mount the backup target onto a NAS/NFS share:

```yaml
# compose.override.yml
services:
  backup:
    volumes:
      - /mnt/nas/glpi-backups:/backups   # phpbu still writes /backups; now on the NAS
```

…or run your existing tool (restic, rclone, Borg) on the host against the
volume's mountpoint. The phpbu config is unchanged either way.
