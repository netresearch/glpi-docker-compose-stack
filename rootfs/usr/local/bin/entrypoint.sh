#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Netresearch DTT GmbH
#
# GLPI php-fpm entrypoint.
#
# Runs as root (via tini), does the privileged setup — secrets, volume
# permission repair, DB wait, first-boot install / in-place schema upgrade,
# Valkey cache wiring — then drops to www-data and execs php-fpm.
#
# Design mirrors the proven official GLPI image flow (database:install on first
# boot, database:update thereafter) but adds: Docker-secrets *_FILE support,
# robust chown for bind-mounts/tmpfs, a maintenance-wrapped upgrade that never
# leaves the instance stuck in maintenance, and idempotent cache configuration.
#
# Hard-fails loudly on misconfiguration — a silent half-start is worse than a
# crash loop the operator can see in `docker compose logs`.

set -eu

GLPI_DIR=/var/www/glpi

log() { printf '[entrypoint] %s\n' "$*" >&2; }

# ---------------------------------------------------------------------
# 1. Docker-secrets *_FILE shim
#
# For any supported VAR, if ${VAR}_FILE points at a readable file (a Docker/
# Compose secret), load its contents into $VAR and drop the _FILE var. Lets
# operators keep the DB password and SMTP creds out of the environment table.
# ---------------------------------------------------------------------
for _var in \
    GLPI_DB_HOST GLPI_DB_PORT GLPI_DB_NAME GLPI_DB_USER GLPI_DB_PASSWORD \
    GLPI_DB_SSL GLPI_DB_SSL_CA GLPI_DB_SSL_CERT GLPI_DB_SSL_KEY \
    GLPI_DB_SSL_CAPATH GLPI_DB_SSL_CIPHER \
    REDIS_HOST REDIS_PORT REDIS_PASSWORD GLPI_CACHE_DSN \
    SMTP_HOST SMTP_PORT SMTP_USER SMTP_PASSWORD
do
    eval "_file=\${${_var}_FILE:-}"
    [ -n "$_file" ] || continue
    if [ ! -r "$_file" ]; then
        log "ERROR: \$${_var}_FILE=$_file is not readable"; exit 1
    fi
    eval "_cur=\${${_var}:-}"
    [ -n "$_cur" ] && log "both \$$_var and \$${_var}_FILE are set — using ${_var}_FILE"
    # shellcheck disable=SC2163
    export "$_var=$(cat "$_file")"
    unset "${_var}_FILE"
done
unset _var _file _cur

# ---------------------------------------------------------------------
# 2. Required vars + defaults
# ---------------------------------------------------------------------
: "${GLPI_DB_HOST:?GLPI_DB_HOST is required (the MariaDB/MySQL host)}"
: "${GLPI_DB_NAME:?GLPI_DB_NAME is required (the GLPI database name)}"
: "${GLPI_DB_USER:?GLPI_DB_USER is required}"
: "${GLPI_DB_PASSWORD:?GLPI_DB_PASSWORD is required}"
export GLPI_DB_PORT="${GLPI_DB_PORT:-3306}"
export TZ="${TZ:-UTC}"
GLPI_AUTOINSTALL="${GLPI_AUTOINSTALL:-true}"
SKIP_DB_WAIT="${SKIP_DB_WAIT:-false}"
SKIP_DB_UPDATE="${SKIP_DB_UPDATE:-false}"
DB_WAIT_TIMEOUT="${DB_WAIT_TIMEOUT:-120}"

# ---------------------------------------------------------------------
# 3. Volume directory init + permission repair  (root)
#
# GLPI writes config_db.php + glpicrypt.key to GLPI_CONFIG_DIR and its whole
# files/ tree to GLPI_VAR_DIR. Create the roots + the _* subdirs GLPI expects,
# then chown them to www-data so a fresh bind-mount/tmpfs is writable.
#
# IMPORTANT: the chown is targeted (the roots and the immediate _* subdirs),
# NOT a recursive sweep of GLPI_VAR_DIR — that tree can hold gigabytes of
# uploaded documents and a recursive chown on every container start would peg
# the CPU. Use GLPI_CHOWN_RECURSIVE=true for a one-off deep fix after a bind-
# mount migration.
# ---------------------------------------------------------------------
for _d in "$GLPI_CONFIG_DIR" "$GLPI_VAR_DIR" "$GLPI_MARKETPLACE_DIR" "$GLPI_LOG_DIR" /run/php-fpm; do
    mkdir -p "$_d"
done
for _sub in _cache _cron _dumps _graphs _locales _lock _pictures _plugins \
            _rss _sessions _tmp _uploads _inventories; do
    mkdir -p "$GLPI_VAR_DIR/$_sub"
done
chown www-data:www-data \
    "$GLPI_CONFIG_DIR" "$GLPI_VAR_DIR" "$GLPI_MARKETPLACE_DIR" "$GLPI_LOG_DIR" \
    /run/php-fpm 2>/dev/null || true
# shellcheck disable=SC2086
chown www-data:www-data "$GLPI_VAR_DIR"/_* 2>/dev/null || true
if [ "${GLPI_CHOWN_RECURSIVE:-false}" = "true" ]; then
    log "GLPI_CHOWN_RECURSIVE=true — recursive chown of state dirs (may be slow)"
    chown -R www-data:www-data \
        "$GLPI_CONFIG_DIR" "$GLPI_VAR_DIR" "$GLPI_MARKETPLACE_DIR" "$GLPI_LOG_DIR" \
        2>/dev/null || true
fi
unset _d _sub

cd "$GLPI_DIR"

# Run a console command as www-data so anything it writes (config_db.php,
# glpicrypt.key, cache files) is owned by the runtime user, not root.
run_console() { su-exec www-data php bin/console "$@"; }

# ---------------------------------------------------------------------
# 4. Wait for the database
#
# mysqli probe via `php -r`, reading every credential through getenv() — the
# password is NEVER interpolated into the shell command, so a quote/metachar
# in it can neither break the probe nor become an injection vector.
# ---------------------------------------------------------------------
if [ "$SKIP_DB_WAIT" = "true" ]; then
    log "SKIP_DB_WAIT=true — not waiting for the database"
else
    log "waiting for database ${GLPI_DB_HOST}:${GLPI_DB_PORT} (timeout ${DB_WAIT_TIMEOUT}s)…"
    _waited=0
    # shellcheck disable=SC2016
    until su-exec www-data php -r '
        $c = @mysqli_init();
        @$c->real_connect(getenv("GLPI_DB_HOST"), getenv("GLPI_DB_USER"),
            getenv("GLPI_DB_PASSWORD"), "", (int) getenv("GLPI_DB_PORT"));
        exit($c->connect_errno ? 1 : 0);
    ' 2>/dev/null; do
        _waited=$((_waited + 2))
        if [ "$_waited" -ge "$DB_WAIT_TIMEOUT" ]; then
            log "ERROR: database not reachable after ${DB_WAIT_TIMEOUT}s"; exit 1
        fi
        sleep 2
    done
    unset _waited
    log "database reachable"
fi

# ---------------------------------------------------------------------
# 5. Install (first boot) or in-place schema upgrade
#
# "Installed" = config_db.php exists AND the schema is present (glpi_configs
# table). The table check makes the decision robust even if a stale
# config_db.php is left on the config volume.
# ---------------------------------------------------------------------
glpi_installed() {
    [ -f "$GLPI_CONFIG_DIR/config_db.php" ] || return 1
    # shellcheck disable=SC2016
    su-exec www-data php -r '
        $c = @mysqli_init();
        if (!@$c->real_connect(getenv("GLPI_DB_HOST"), getenv("GLPI_DB_USER"),
                getenv("GLPI_DB_PASSWORD"), getenv("GLPI_DB_NAME"),
                (int) getenv("GLPI_DB_PORT"))) { exit(1); }
        $r = $c->query("SHOW TABLES LIKE \"glpi_configs\"");
        exit(($r && $r->num_rows > 0) ? 0 : 1);
    ' 2>/dev/null
}

if glpi_installed; then
    if [ "$SKIP_DB_UPDATE" = "true" ]; then
        log "GLPI already installed; SKIP_DB_UPDATE=true — not upgrading"
    else
        log "GLPI installed — applying database:update (maintenance-wrapped)…"
        # Enable maintenance so other replicas/web hits don't touch a half-
        # migrated schema. enable/disable failures are non-fatal (a stale
        # maintenance flag must never wedge the container), but the update rc
        # is captured and re-raised AFTER maintenance is disabled — the app is
        # never left in maintenance just because the upgrade failed.
        run_console maintenance:enable --no-interaction --quiet 2>/dev/null \
            || log "maintenance:enable failed (continuing)"
        _rc=0
        run_console database:update --no-interaction --quiet || _rc=$?
        run_console maintenance:disable --no-interaction --quiet 2>/dev/null \
            || log "maintenance:disable failed (continuing)"
        if [ "$_rc" -ne 0 ]; then
            log "ERROR: database:update failed (rc=$_rc)"; exit "$_rc"
        fi
        unset _rc
        log "database:update complete"
    fi
elif [ "$GLPI_AUTOINSTALL" = "true" ]; then
    log "fresh instance — running database:install…"
    # Build the install argv inside a function so `set --` rewrites the
    # FUNCTION's positional params, not the script's — the script's $@ (the
    # CMD, php-fpm) must survive untouched for the final exec.
    do_install() {
        set -- database:install \
            --db-host="$GLPI_DB_HOST" --db-port="$GLPI_DB_PORT" \
            --db-name="$GLPI_DB_NAME" --db-user="$GLPI_DB_USER" \
            --db-password="$GLPI_DB_PASSWORD"
        if [ "${GLPI_DB_SSL:-false}" = "true" ]; then
            set -- "$@" --db-ssl
            [ -n "${GLPI_DB_SSL_CA:-}" ]     && set -- "$@" --db-ssl-ca="$GLPI_DB_SSL_CA"
            [ -n "${GLPI_DB_SSL_CERT:-}" ]   && set -- "$@" --db-ssl-cert="$GLPI_DB_SSL_CERT"
            [ -n "${GLPI_DB_SSL_KEY:-}" ]    && set -- "$@" --db-ssl-key="$GLPI_DB_SSL_KEY"
            [ -n "${GLPI_DB_SSL_CAPATH:-}" ] && set -- "$@" --db-ssl-capath="$GLPI_DB_SSL_CAPATH"
            [ -n "${GLPI_DB_SSL_CIPHER:-}" ] && set -- "$@" --db-ssl-cipher="$GLPI_DB_SSL_CIPHER"
        fi
        run_console "$@" --default-language="${GLPI_DEFAULT_LANGUAGE:-en_GB}" \
            --no-telemetry --no-interaction --quiet
    }
    do_install
    log "database:install complete — default login is glpi/glpi; CHANGE IT IMMEDIATELY."
else
    log "GLPI not installed and GLPI_AUTOINSTALL=false — skipping install (manual setup expected)"
fi

# ---------------------------------------------------------------------
# 6. Encryption-key preservation guard
#
# glpicrypt.key (in GLPI_CONFIG_DIR) is the AES key for every encrypted DB
# field (stored passwords, plugin secrets). It is created once at install and
# must NEVER be regenerated — a new key makes existing ciphertext permanently
# unreadable. We do not touch it; if it has gone missing while the DB is
# installed, warn loudly rather than silently minting a fresh (useless) one.
# ---------------------------------------------------------------------
if [ -f "$GLPI_CONFIG_DIR/config_db.php" ] && [ ! -f "$GLPI_CONFIG_DIR/glpicrypt.key" ]; then
    log "WARNING: config_db.php present but glpicrypt.key is MISSING."
    log "WARNING: encrypted DB fields will be unreadable. Restore the original"
    log "WARNING: key from backup — do NOT let GLPI generate a new one."
fi

# ---------------------------------------------------------------------
# 7. Cache (Valkey/Redis) wiring — idempotent
#
# Point GLPI's 'core' cache context at Valkey. Guarded by a marker so we only
# reconfigure when the DSN actually changes (cache:configure rewrites config on
# every call otherwise). Falls back silently to the filesystem cache on error.
# ---------------------------------------------------------------------
if [ -n "${GLPI_CACHE_DSN:-}" ] || [ -n "${REDIS_HOST:-}" ]; then
    _dsn="${GLPI_CACHE_DSN:-redis://${REDIS_HOST}:${REDIS_PORT:-6379}}"
    # The marker stores only a SHA-256 of the DSN, never the DSN itself — a
    # DSN may carry a Redis password (redis://:pw@host) that must not be
    # persisted (or logged) in cleartext.
    _dsn_hash="$(printf '%s' "$_dsn" | sha256sum | cut -d' ' -f1)"
    _marker="$GLPI_VAR_DIR/_cache/.configured-dsn"
    if [ "$(cat "$_marker" 2>/dev/null || true)" != "$_dsn_hash" ]; then
        log "configuring GLPI core cache backend"
        if run_console cache:configure --context=core --dsn="$_dsn" --no-interaction --quiet; then
            printf '%s' "$_dsn_hash" | su-exec www-data tee "$_marker" >/dev/null 2>&1 || true
        else
            log "cache:configure failed — continuing with the filesystem cache"
        fi
    fi
    unset _dsn _dsn_hash _marker
fi

# ---------------------------------------------------------------------
# 7b. PHP session cookie Secure flag
#
# php.ini can't expand env vars, so the image ships session.cookie_secure = 0
# (works on plain-HTTP local bring-up). Write a conf.d drop-in from
# SESSION_COOKIE_SECURE here so HTTPS deployments (behind a TLS-terminating
# proxy) get the Secure flag without a custom image. php-fpm reads conf.d at
# startup, just below.
# ---------------------------------------------------------------------
case "${SESSION_COOKIE_SECURE:-0}" in
    1 | true | on | yes) _secure=1 ;;
    *) _secure=0 ;;
esac
printf 'session.cookie_secure = %s\n' "$_secure" \
    > /usr/local/etc/php/conf.d/zz-session-secure.ini
unset _secure

# ---------------------------------------------------------------------
# 8. Exec the main process
#
# php-fpm runs its MASTER as root (so it can open the global error_log fd and
# honour the pool's `user = www-data` directive) and drops every WORKER — where
# all request handling and any untrusted code runs — to www-data. That is the
# standard, correct php-fpm privilege model; the container's cap_drop/no-new-
# privileges in compose.yml bound the root master. The console steps above
# already ran as www-data via su-exec, so files they created are owned right.
# ---------------------------------------------------------------------
log "starting: $*"
exec "$@"
