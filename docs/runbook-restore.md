<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- Copyright (c) 2026 Netresearch DTT GmbH -->

# Runbook — Restore from backup

This is the canonical recovery procedure when the stack's database or
user-uploaded content is lost, corrupted, or needs to be rolled back to
a known-good snapshot. Backups are produced nightly by the `backup` service
(see `config/phpbu/backup.json`).

## Backup artefacts

Located in the `glpi-backups` volume (bind-mount it onto an off-host
share for disaster-survival), organised into three subdirectories:

| Path | What | Cadence | Retention |
|---|---|---|---|
| `/backups/db/glpi-db-*.sql.gz` | `mariadb-dump` of the application DB (single-transaction, routines + triggers) | nightly 03:00 | rolling 5 GB |
| `/backups/uploads/glpi-uploads-*.tar.gz` | tar of `app-data` volume (GLPI uploads / EULAs / barcodes) | nightly 03:00 | 30 days |
| `/backups/storage/glpi-storage-*.tar.gz` | tar of `app-storage` volume (Laravel storage, including the cached config) | nightly 03:00 | 30 days |
| `/backups/phpbu.log` | structured JSON log of phpbu runs (success and failure) | per-run append | rotated by phpbu |

`make backup-list` shows what's currently on disk.

## Restore — full disaster (DB + uploads + storage)

### 1. Stop the running stack

```bash
docker compose stop app web scheduler
# Leave `db`, `valkey`, and `backup` up — we need db to receive the restore.
```

### 2. Identify the snapshot to restore from

```bash
make backup-list
# Pick the SQL file you want — typically the most recent. Note the timestamp.
TIMESTAMP=20260521-030001   # adjust to your chosen file
```

### 3. Drop and recreate the application database

This is destructive. The `mariadb-dump` artefact contains the schema and
data — we're swapping in the backed-up state wholesale.

```bash
docker compose exec -T db sh -c '
  mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "
    DROP DATABASE IF EXISTS glpi;
    CREATE DATABASE glpi CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
    GRANT ALL ON glpi.* TO glpi@'%';
    FLUSH PRIVILEGES;"'
```

### 4. Replay the SQL dump

```bash
docker compose exec -T backup sh -c "
  zcat /backups/db/glpi-db-${TIMESTAMP}.sql.gz" \
  | docker compose exec -T db sh -c '
    mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" glpi'
```

For a large dump this can take minutes — let it finish.

### 5. Restore the uploads volume

```bash
docker compose run --rm -v glpi-app-data:/restore \
  backup sh -c "
    cd /restore && \
    rm -rf ./* ./.[!.]* 2>/dev/null || true && \
    tar xzf /backups/uploads/glpi-uploads-${TIMESTAMP}.tar.gz --strip-components=2"
```

`--strip-components=2` peels the `/snapshot/data/` prefix that phpbu added
when it captured the tree.

### 6. Restore the storage volume

```bash
docker compose run --rm -v glpi-app-storage:/restore \
  backup sh -c "
    cd /restore && \
    rm -rf ./* ./.[!.]* 2>/dev/null || true && \
    tar xzf /backups/storage/glpi-storage-${TIMESTAMP}.tar.gz --strip-components=2"
```

### 7. Clear caches and bring the stack back up

The restored storage volume contains the **old** cached config. Clear it
before the app re-mounts the cache:

```bash
docker compose run --rm app sh -c "
  rm -f bootstrap/cache/config.php bootstrap/cache/routes-*.php bootstrap/cache/events.php"
docker compose start app web scheduler
docker compose logs -f --tail=50 app
```

### 8. Verify

```bash
# 1. HTTP responds:
curl -sI http://localhost:8000/login | head -1

# 2. Log in via browser and confirm assets visible.
# 3. Compare a known asset count:
docker compose exec -T db sh -c '
  mariadb -uglpi -p"$DB_PASSWORD" -e "SELECT COUNT(*) FROM assets;" glpi'
```

## Restore — database only

Skip steps 5 and 6. App will use its current uploads + storage with the
restored DB. Useful for "undo an incorrect bulk update on assets" type
incidents.

Caveat: if the DB references uploaded files (avatars, EULAs) that were
*added after* the snapshot, those files exist on disk but GLPI won't
reference them (they're orphans). And uploads referenced by the restored
DB that were *deleted later* are missing 404s. For point-in-time fidelity,
restore all three.

## Restore — older revision via binlog (advanced)

The DB service has `--log-bin=mariadb-bin --binlog-format=ROW
--expire-logs-days=14` enabled, so PITR within the last 14 days is possible:

```bash
# 1. Restore the latest dump BEFORE the bad event
# 2. Apply binlogs up to a specific timestamp:
docker compose exec -T db sh -c '
  mariadb-binlog --start-datetime="2026-05-21 09:00:00" \
                 --stop-datetime="2026-05-21 14:30:00" \
                 /var/lib/mysql/mariadb-bin.* \
  | mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" glpi'
```

## Rollback to a previous image tag

If the issue is a broken GLPI release, not lost data:

```bash
# .env: set GLPI_IMAGE_TAG=8.5.0-20260520  (or any dated tag)
docker compose pull app app-assets
docker compose up -d
# Migrations roll forward; the image carries its own migration state.
```

Note: GLPI migrations are forward-only. Restoring an *older* image
against a DB migrated by a *newer* image will produce schema errors. In
that case do a full DB+image restore from the corresponding day's snapshot.

## Backup-verify (read-only sanity check)

`make backup-verify` runs phpbu in `--simulate` mode, plus checks that
last night's dump is on disk and not zero-byte. It does NOT restore — use
it to confirm the backup pipeline is working without disrupting
production.

## Off-host shipping

`glpi-backups` is a local Docker volume. Survives container restart
but not host loss. For real disaster recovery, configure your existing
backup tool (restic, rclone, BorgBackup, etc.) to read from the volume
mount point on the host. Example bind-mount snippet for `compose.yml`:

```yaml
backup:
  volumes:
    - /mnt/nas/glpi-backups:/backups   # NAS-mounted destination
```

Replace `/mnt/nas/glpi-backups` with your real destination. The
phpbu config is unchanged — it still writes to `/backups` inside the
container; that path is now on your NAS.
