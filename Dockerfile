# syntax=docker/dockerfile:1.7
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Netresearch DTT GmbH

# GLPI php-fpm image — only PHP + the GLPI application code.
# Web serving (nginx), scheduling (ofelia), and DB (mariadb) live in
# separate containers in compose.yml. This image is single-purpose.
#
# Two stages:
#   1. fetch   — downloads + verifies the bundled GLPI release tarball
#   2. runtime — minimal php-fpm with the app code, runs as www-data
#
# GLPI ships a *bundled* release tarball (glpi-<version>.tgz) with vendor/
# already installed, so — unlike a Composer-based app — there is NO composer
# install step and no build-time GitHub rate-limit to manage. That makes this
# image both simpler and more reproducible than its Snipe-IT sibling.
#
# Build args:
#   PHP_VERSION     — base PHP version (default 8.4; GLPI 11.0.x is tested on
#                     PHP 8.2-8.4. 8.5 is intentionally NOT the default — GLPI
#                     11.0.x has not been validated against it upstream.)
#   ALPINE_VERSION  — Alpine tag for the php images (default 3.21)
#   GLPI_VERSION    — GLPI release (default 11.0.8 — keep in sync with .glpi-version)
#   GLPI_SHA256     — sha256 of glpi-${GLPI_VERSION}.tgz (supply-chain pin; "" skips)

# renovate: datasource=docker depName=php versioning=docker
ARG PHP_VERSION=8.4
# renovate: datasource=docker depName=alpine versioning=docker
ARG ALPINE_VERSION=3.24

# =====================================================================
# Stage 1: fetch — download + verify the bundled GLPI release tarball
# =====================================================================
FROM alpine:${ALPINE_VERSION} AS fetch

# pipefail — surface errors in piped curl downloads (hadolint DL4006)
SHELL ["/bin/ash", "-o", "pipefail", "-c"]

ARG GLPI_VERSION=11.0.8
# Optional integrity pin. When set, the download is rejected unless its
# sha256 matches — closes a supply-chain gap (a swapped release asset can't
# slip through). Left empty by default so a bare `docker build` works; CI
# (build.yml) passes the value resolved from the release at build time.
ARG GLPI_SHA256=""

RUN set -eux; \
    apk add --no-cache curl ca-certificates tar; \
    curl -fsSL -o /tmp/glpi.tgz \
        "https://github.com/glpi-project/glpi/releases/download/${GLPI_VERSION}/glpi-${GLPI_VERSION}.tgz"; \
    if [ -n "${GLPI_SHA256}" ]; then \
        echo "${GLPI_SHA256}  /tmp/glpi.tgz" | sha256sum -c -; \
    else \
        echo "[fetch] GLPI_SHA256 not provided — skipping integrity check (set it in CI)"; \
    fi; \
    mkdir -p /opt/glpi; \
    # The tarball's top-level dir is `glpi/` — strip it so the app root is /opt/glpi.
    tar xzf /tmp/glpi.tgz -C /opt/glpi --strip-components=1; \
    rm -f /tmp/glpi.tgz; \
    # Sanity: the bundled dist must carry vendor/, the public/ docroot and the CLI.
    test -f /opt/glpi/public/index.php; \
    test -f /opt/glpi/bin/console; \
    test -d /opt/glpi/vendor; \
    # The release tarball ships an empty `files/` and `config/` under the code
    # root. We relocate those to volumes (GLPI_VAR_DIR / GLPI_CONFIG_DIR), so
    # drop the in-tree copies to keep the code layer read-only and clean.
    rm -rf /opt/glpi/files /opt/glpi/config; \
    # Record the version for ops introspection.
    echo "${GLPI_VERSION}" > /opt/glpi/VERSION

# =====================================================================
# Stage 2: runtime — php-fpm only
# =====================================================================
FROM php:${PHP_VERSION}-fpm-alpine${ALPINE_VERSION} AS runtime

# pipefail — surface errors in piped downloads (hadolint DL4006)
SHELL ["/bin/ash", "-o", "pipefail", "-c"]

ARG GLPI_VERSION=11.0.8
ARG PHP_VERSION=8.4
ARG BUILD_DATE
ARG VCS_REF

LABEL org.opencontainers.image.title="glpi-php-fpm" \
      org.opencontainers.image.description="GLPI ${GLPI_VERSION} on PHP ${PHP_VERSION} / Alpine — php-fpm only (use with glpi-docker-compose-stack)" \
      org.opencontainers.image.url="https://github.com/netresearch/glpi-docker-compose-stack" \
      org.opencontainers.image.source="https://github.com/netresearch/glpi-docker-compose-stack" \
      org.opencontainers.image.documentation="https://github.com/netresearch/glpi-docker-compose-stack#readme" \
      org.opencontainers.image.vendor="Netresearch DTT GmbH" \
      org.opencontainers.image.licenses="GPL-3.0-or-later" \
      org.opencontainers.image.version="${GLPI_VERSION}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${VCS_REF}"

# GLPI reads these to locate its mutable state OUTSIDE the (read-only) code
# root, so config/files/plugins/logs all live on named volumes:
#   GLPI_CONFIG_DIR      — config_db.php + glpicrypt.key + local config
#   GLPI_VAR_DIR         — files/ tree (cache, sessions, uploads, pictures, …)
#   GLPI_MARKETPLACE_DIR — marketplace-installed plugins
#   GLPI_LOG_DIR         — application logs
# Using env vars (not inc/downstream.php) is the reliable path on GLPI 11
# (downstream-based relocation has open bugs — glpi-project/glpi#23103).
ENV GLPI_CONFIG_DIR=/etc/glpi \
    GLPI_VAR_DIR=/var/lib/glpi/files \
    GLPI_MARKETPLACE_DIR=/var/lib/glpi/plugins \
    GLPI_LOG_DIR=/var/log/glpi

# Runtime libraries (no -dev) the extensions link against, plus the small
# operational toolset the entrypoint/healthcheck need (tini for signal
# handling, su-exec for privilege drop, fcgi for the cgi-fcgi healthcheck).
RUN set -eux; \
    apk add --no-cache \
        bash ca-certificates curl tini su-exec fcgi tzdata \
        icu-libs libpng libjpeg-turbo freetype libzip \
        oniguruma libldap libsodium libbz2 libxml2 \
    # Build deps in a virtual package so they can be dropped in the same layer.
    && apk add --no-cache --virtual .build-deps \
        $PHPIZE_DEPS \
        icu-dev libpng-dev libjpeg-turbo-dev freetype-dev libzip-dev \
        oniguruma-dev openldap-dev libsodium-dev bzip2-dev \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j"$(nproc)" \
        bcmath bz2 exif gd intl ldap mbstring mysqli opcache sodium zip \
    # phpredis — required for GLPI's redis/valkey cache backend
    # (cache:configure refuses a redis:// DSN without it). Pinned for
    # reproducible builds; bump deliberately.
    && pecl install redis-6.3.0 \
    && docker-php-ext-enable redis \
    && apk del .build-deps \
    && rm -rf /tmp/* /var/cache/apk/* /usr/src/php* \
        /usr/local/lib/php/test /usr/local/lib/php/doc \
    # Fail the build loudly if any required extension is missing. `php -m`
    # lists OPcache as "Zend OPcache", so it is checked separately below
    # rather than as a bare "opcache" line.
    && php -m | tr '[:upper:]' '[:lower:]' | sort > /tmp/mods \
    && for ext in bcmath ctype curl dom exif fileinfo filter gd iconv intl \
                  ldap mbstring mysqli openssl redis session simplexml sodium \
                  tokenizer zip zlib; do \
           grep -qx "$ext" /tmp/mods || { echo "MISSING ext: $ext" >&2; exit 1; }; \
       done \
    && grep -qx "zend opcache" /tmp/mods || { echo "MISSING ext: opcache" >&2; exit 1; } \
    && rm -f /tmp/mods

WORKDIR /var/www/glpi

# Defense-in-depth: application code is owned by root and only readable (not
# writable) by the www-data group. A compromised php-fpm worker (www-data)
# cannot modify GLPI's PHP source, vendor/ or public/ assets at runtime.
# The paths GLPI legitimately writes to (GLPI_CONFIG_DIR / GLPI_VAR_DIR /
# GLPI_MARKETPLACE_DIR / GLPI_LOG_DIR and /run/php-fpm) are chown'd www-data
# below — and again by entrypoint.sh, to survive fresh volume mounts.
COPY --from=fetch --chown=root:www-data /opt/glpi /var/www/glpi
COPY rootfs/ /

# All runtime-stage filesystem setup folded into one layer:
#   1. create the writable state dirs (relocated off the code root),
#   2. chown them + the php-fpm socket dir to www-data,
#   3. mark the entrypoint executable.
# Each is re-applied by entrypoint.sh at container start so it works whether
# the operator mounts named volumes (image chown survives until first write),
# bind-mounts (host UID wins — entrypoint fixes it) or tmpfs (mount masks the
# image chown — entrypoint fixes it).
RUN set -eux; \
    mkdir -p /etc/glpi /var/lib/glpi/files /var/lib/glpi/plugins \
             /var/log/glpi /run/php-fpm \
    && chown -R www-data:www-data \
        /etc/glpi /var/lib/glpi /var/log/glpi /run/php-fpm \
    && chmod 0755 /usr/local/bin/entrypoint.sh

# --start-interval=5s probes every 5s during the start_period instead of
# waiting the full --interval, so `docker compose up --wait` returns as soon
# as php-fpm accepts FastCGI rather than 30s+ later. The probe pings php-fpm's
# own /ping endpoint (configured in php-fpm.d/zz-glpi.conf) over the unix
# socket — it proves the worker pool is alive, independent of DB/app state.
HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --start-interval=5s --retries=3 \
    CMD SCRIPT_NAME=/ping SCRIPT_FILENAME=/ping REQUEST_METHOD=GET \
        cgi-fcgi -bind -connect /run/php-fpm/glpi.sock 2>/dev/null \
        | grep -q "pong" || exit 1

# Graceful php-fpm shutdown: tini forwards the orchestrator's SIGTERM, but
# php-fpm reads SIGTERM as "fast shutdown" (kills in-flight requests). SIGQUIT
# is php-fpm's graceful drain — finish active requests, then exit. Critical
# during rolling updates so users mid-request don't see 502s.
STOPSIGNAL SIGQUIT

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["php-fpm", "--nodaemonize"]
