<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- Copyright (c) 2026 Netresearch DTT GmbH -->

# Migration: from `snipe/glpi` single-container to this stack

You're running GLPI on the upstream `snipe/glpi:vX.Y.Z-alpine`
image — Apache, PHP-FPM, and cron stuffed into one container — and you
want to move to this opinionated multi-container stack without losing
data and without an open-ended downtime window. This guide walks
through that move the way an experienced operator would: snapshot what
you have, prepare the new home on the side, then do a short cutover
with a clean rollback path if anything looks wrong. Allow about 30
minutes; the cutover itself runs in roughly 10, but a slow DB restore
or reverse-proxy hiccup will eat the rest.

## What's actually changing

Upstream's container is one process tree doing everything: Apache
fronting PHP-FPM, system cron firing Laravel's scheduler, file-system
caches because there's nowhere else to put them. This stack splits
those responsibilities across services that each do one thing.

| Concern | Upstream single-container | This stack |
|---------|---------------------------|------------|
| Web server | Apache (in-container) | nginx (`web` service) |
| PHP runtime | mod_php / fpm (in-container) | `app` service — `ghcr.io/netresearch/glpi-php-fpm` |
| Scheduler / cron | system cron in-container | `scheduler` service (ofelia, Docker-native) |
| Cache / sessions | filesystem default | `valkey` service (RESP-compatible Redis fork) |
| Database | external (you provide) | `db` service (MariaDB 11) — bring-your-own DB also supported |
| Backups | external (you provide) | optional `backup` service (phpbu-docker) |
| Image scope | everything | each container does one thing |

The PHP-FPM image is multi-arch (`linux/amd64` + `linux/arm64`), ships
with SLSA build provenance attestations, and rebuilds nightly so base-OS
and Composer-dep CVE patches land without waiting for an upstream tag.
The other services use upstream images.

## Before you start

Three things save a 2 AM call to a colleague.

**Find your `APP_KEY` and copy it somewhere safe.** GLPI encrypts a
handful of columns at rest — asset checkout history, LDAP bind
passwords. A different `APP_KEY` on the new stack leaves those columns
as silent garbage: UI renders fine, rows exist, but the content is
unreadable. Copy the key, verify you can read it back, keep that copy
until the new stack has been running a few days.

**Inventory your volumes.** On the old host, `docker volume ls` and
`docker compose -p <current-project> config | grep image:` will tell
you what's mounted. Upstream's image typically uses one volume at
`/var/lib/glpi` (uploads) and another at `/var/www/html/storage`
(Laravel storage). Note the exact names; you'll feed them to the
snapshot step.

**Plan the network topology.** If a reverse proxy currently targets the
upstream container's Apache, the new backend will be this stack's `web`
service on its `glpi` Docker network. External proxies just need the
new upstream address; in-Compose proxies need their network attached to
`web` via `compose.override.yml`. Figure this out before downtime.

A handful of shell variables make the rest readable:

```bash
export DEPLOY_DIR=/srv/www/glpi-new       # where the new stack lives
export BACKUP_DIR=/srv/backup/glpi-migration
export LEGACY_DIR=/srv/www/glpi            # current upstream stack
mkdir -p "$BACKUP_DIR"
```

## Take the snapshot while the lights are still on

This runs against the running legacy stack — no downtime yet.

```bash
cd "$LEGACY_DIR"

# Database dump. Use whatever env var the upstream container exposes
# for the root password (commonly MYSQL_ROOT_PASSWORD); the single
# quotes around the inner script keep the expansion inside the
# container, where the variable actually exists.
docker compose exec -T db sh -c '
  mysqldump --single-transaction -uroot -p"$MYSQL_ROOT_PASSWORD" glpi
' > "$BACKUP_DIR/glpi-pre-migration.sql"

# Uploads + Laravel storage. Replace <UPLOADS_VOLUME> and
# <STORAGE_VOLUME> with the actual names from `docker volume ls`.
docker run --rm -v <UPLOADS_VOLUME>:/uploads -v "$BACKUP_DIR":/backup \
  alpine tar czf /backup/uploads.tar.gz -C /uploads .
docker run --rm -v <STORAGE_VOLUME>:/storage -v "$BACKUP_DIR":/backup \
  alpine tar czf /backup/storage.tar.gz -C /storage .

# Keep the old .env — your APP_KEY source of truth and reference for
# mail / LDAP / SAML.
cp .env "$BACKUP_DIR/.env.pre-migration"
```

`ls -lah "$BACKUP_DIR"/` should show three non-empty artefacts plus the
env snapshot. If any of them looks suspiciously small, stop and
investigate — you don't want to discover an empty dump on the other
side of downtime.

## Stand up the new stack on the side

Clone, fill in `.env`, leave it stopped until cutover:

```bash
git clone https://github.com/netresearch/glpi-docker-compose-stack.git "$DEPLOY_DIR"
cd "$DEPLOY_DIR"
cp .env.example .env
```

Edit `.env`. The values that matter:

- `APP_KEY` — paste the value you copied from the old `.env`. Same
  string, no edits. Non-negotiable.
- `DB_PASSWORD` and `DB_ROOT_PASSWORD` — pick fresh strong values. The
  new `db` service gets initialised by the first `up`, so these are
  creating credentials, not matching old ones.
- `MAIL_*`, LDAP, SAML, OIDC, SSO — copy verbatim from the snapshot.
- `APP_URL` — your public URL, no trailing slash.

Reverse-proxy labels and other site-specific tweaks go in
`compose.override.yml` (gitignored, survives `git pull`):

```yaml
# compose.override.yml — local-only overrides
services:
  web:
    labels:
      # Your proxy labels go here. They previously applied to the
      # upstream Apache container; now they apply to this stack's
      # nginx `web` service.
      # Example for Traefik:
      # - "traefik.enable=true"
      # - "traefik.http.routers.glpi.rule=Host(`assets.example.org`)"
```

Don't `docker compose up` yet — that happens during cutover, with the
old stack already stopped, so you don't race two stacks against the
same hostname.

## The cutover

This is the short stretch where the dashboard is dark. Work straight
through. Stop the old stack, bring DB + cache up first (so the restore
has somewhere to land), replay the SQL dump, restore the file volumes,
then bring the web tier up.

```bash
# Old stack down. Dashboard goes dark — this is downtime now.
cd "$LEGACY_DIR"
docker compose down
```

Bring up only DB and cache from the new stack and wait for MariaDB:

```bash
cd "$DEPLOY_DIR"
docker compose up -d db valkey

# The root password lives inside the container as
# MARIADB_ROOT_PASSWORD (compose.yml populates it from .env's
# DB_ROOT_PASSWORD). Single quotes keep the variable expansion inside
# the container.
docker compose exec -T db sh -c '
  until mariadb-admin ping -uroot -p"$MARIADB_ROOT_PASSWORD" --silent; do
    sleep 1
  done
'
```

Once the ping loop exits, restore the dump — same trick, password
expanded inside the container:

```bash
docker compose exec -T db sh -c '
  mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" glpi
' < "$BACKUP_DIR/glpi-pre-migration.sql"
```

Now restore the file volumes. This stack pins explicit volume names in
`compose.yml` (`name: glpi-app-data`, `name: glpi-app-storage`,
etc.), so the names below are exactly the literal names Docker
created — no project-name prefix, no dependency on what you called
`$DEPLOY_DIR`.

```bash
docker run --rm -v glpi-app-data:/data -v "$BACKUP_DIR":/backup \
  alpine tar xzf /backup/uploads.tar.gz -C /data
docker run --rm -v glpi-app-storage:/storage -v "$BACKUP_DIR":/backup \
  alpine tar xzf /backup/storage.tar.gz -C /storage
```

> **Heads-up:** the literal names work because this stack's
> `compose.yml` explicitly pins them. If you wrote your own
> `compose.yml` without the `name:` keys, default Compose naming
> applies (`<project>_<volume>`) and these literal names won't match.
> `docker volume ls` right after `up -d db valkey` is the fastest way
> to confirm what Docker actually created.

Bring everything else up and wait for healthchecks:

```bash
docker compose up -d --wait
```

`--wait` blocks until every service with a healthcheck reports healthy.
If it returns non-zero, jump to the troubleshooting section below.

## How you know it worked

Test the canary first. Open the UI, log in, click into an asset with a
checkout history, and confirm the "checked out to" entries render
readable user names — **not corrupted bytes.** That's the test that
matters: if it fails, the `APP_KEY` did not transfer correctly. Stop
and roll back.

If checkouts read clean, walk through the rest:

```bash
docker compose ps                                # every service healthy
curl -fsS -I http://localhost:8000/ | head -5    # HTTP reachable

# Smoke-check counts
docker compose exec app php artisan tinker --execute='echo "Users: " . \App\Models\User::count() . PHP_EOL;'
docker compose exec app php artisan tinker --execute='echo "Assets: " . \App\Models\Asset::count() . PHP_EOL;'

# Scheduler alive and talking to Docker
docker compose logs scheduler --tail=20
```

The scheduler log should show `successfully connected to docker
socket` and, within a minute, the first `glpi-schedule` and
`glpi-heartbeat` job executions. Run one report from the UI for
good measure, then watch `docker compose logs -f app` for a couple of
minutes — no stack traces, no decryption warnings, no 500s.

## If something goes wrong

The new stack only writes to its own volumes during cutover, so
rollback is fast:

```bash
cd "$DEPLOY_DIR" && docker compose down
cd "$LEGACY_DIR" && docker compose up -d
```

The snapshot in `$BACKUP_DIR` is your worst-case insurance.

**Encrypted columns look corrupted.** UI loads, lists render, but
checkout-to fields and LDAP-derived data look like garbage or trigger
"decryption failed" in `storage/logs/laravel.log`. Almost always an
`APP_KEY` mistyped or pasted with trailing whitespace. Fix `APP_KEY` in
`.env`, `docker compose restart app`, recheck. If the key really did
transfer correctly and it still fails, roll back.

**Reverse proxy returns 502.** The proxy is reaching something but not
the right thing — usually still targeting the old service name or
network. Update the proxy's upstream to the new `web` service, or
attach `web` to whichever Docker network your proxy uses. The stack's
own network is named `glpi`.

**Scheduler logs say permission denied on the docker socket.** Ofelia
needs the host's `/var/run/docker.sock` to `docker exec`
`schedule:run` into `app`. Check the `scheduler` service's volume mount
against the actual socket path on your host. Most distributions work
unchanged; rootless Docker setups expose the socket elsewhere.

## After the dust settles

Give the new stack a day or two of normal traffic. Let one nightly
`phpbu` run finish (default 03:00) so you've proven the backup loop
end-to-end. Then archive the legacy directory rather than deleting:

```bash
mv "$LEGACY_DIR" "${LEGACY_DIR}.archive-$(date +%Y%m%d)"
# If your new deploy dir has a temporary suffix:
# mv "$DEPLOY_DIR" "$LEGACY_DIR"
docker image rm snipe/glpi:vX.Y.Z-alpine
```

Keep the migration snapshots in `$BACKUP_DIR` for ~30 days. After that,
the stack's nightly `phpbu` artefacts cover you.

## Staying current

Subscribe to releases on
[netresearch/glpi-docker-compose-stack](https://github.com/netresearch/glpi-docker-compose-stack/releases)
so notable changes reach you. For routine updates, `make upgrade` pulls
the latest images and recreates containers; the `app` entrypoint runs
`php artisan migrate --force` on every start, so schema bumps are
automatic.

For day-2 troubleshooting, [`runbook-day2-ops.md`](runbook-day2-ops.md)
catalogues the failure modes we've seen in production; for worst-case
disaster recovery from `phpbu` artefacts, [`runbook-restore.md`](runbook-restore.md)
is the canonical procedure.
