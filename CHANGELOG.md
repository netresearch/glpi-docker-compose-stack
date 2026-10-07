<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- Copyright (c) 2026 Netresearch DTT GmbH -->

# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project aims to follow [Semantic Versioning](https://semver.org/).
Release tags track the bundled GLPI version (bare semver, no `v` prefix).

## [Unreleased]

Initial release of the GLPI Docker Compose stack — a hardened, self-contained
deployment of [GLPI](https://glpi-project.org/) built around a purpose-built
`glpi-php-fpm` image.

### Added

- **`glpi-php-fpm` image** built **from the bundled GLPI release tarball**
  (vendor/ already included — no Composer step), on PHP 8.5 / Alpine 3.24, with
  the extensions GLPI needs: bcmath, bz2, exif, gd, intl, ldap, mbstring,
  mysqli, opcache, redis, sodium, zip.
  - Two-stage build with a `GLPI_SHA256` supply-chain integrity pin on the
    downloaded tarball.
  - Non-root (`www-data`) php-fpm over a Unix socket, read-only application
    code layer, php-fpm `/ping` HEALTHCHECK, and graceful `SIGQUIT` shutdown.
  - Mutable state relocated onto named volumes (config, files, plugins, logs)
    so the code layer stays immutable.
  - Multi-architecture images (linux/amd64, linux/arm64).
- **Hardened Compose stack** with services for the database (MariaDB 11 with
  point-in-time recovery), Valkey (GLPI cache), a one-shot public-asset sync,
  the GLPI app, nginx, the ofelia scheduler (runs GLPI's `front/cron.php`), and
  a phpbu backup job that archives the config directory — including the
  irreplaceable `glpicrypt.key`.
  - `no-new-privileges:true` on every long-running service, `cap_drop: ALL`
    with minimal re-adds on the application and web containers, read-only
    mounts, tmpfs sockets, and a loopback-bound web port by default.
- **Opt-in overlays** under `examples/` (Traefik and Caddy reverse proxies, and
  a Prometheus + Grafana observability stack), each shipping with the same
  hardening posture.
- **Supply-chain & CI**: daily multi-arch rebuild to absorb base-image CVE
  fixes, keyless Cosign signatures, in-image SBOMs, SLSA build provenance,
  daily Trivy vulnerability scanning, OpenSSF Scorecard, and a lint suite
  (hadolint, shellcheck, yamllint, actionlint) plus bats and smoke tests.
  - `docker-bake.hcl` and a tag-triggered `release.yml` that builds, signs and
    publishes the canonical tag set (`<version>`, `<major.minor>`, `<major>`,
    `latest`); a weekly GHCR retention job prunes untagged versions.
- **Automated updates** via Renovate (base images, PHP packages, GLPI version
  pin) with Dependabot covering GitHub Actions.
- **Documentation**: README, migration guide, day-2 operations and restore
  runbooks, plus the standard community files (CONTRIBUTING, CODE_OF_CONDUCT,
  SECURITY) and a `pre-commit` configuration mirroring the CI lint gate.

### Changed

- Bundled GLPI raised from 11.0.11 to 12.0.0, the new major release.
  Release notes: https://github.com/glpi-project/glpi/releases/tag/12.0.0
  - The existing database is migrated on the first start of the new image.
    An 11.x image cannot run against the migrated schema; going back needs a
    database restore.
  - `latest`, `12` and `12.0` now point to GLPI 12, so a deployment on
    `latest` (the `.env.example` default) upgrades with its next pull. The
    `11`, `11.0` and `11.0.x` tags are no longer rebuilt.
  - GLPI 12 makes knowledge base categories invisible on upgrade until access
    is granted to them again.
- PHP raised from 8.4 to 8.5, the highest version GLPI 12 supports (8.3 to 8.5). OPcache is
  part of the PHP 8.5 core, so the image builds it as an extension only on an
  older `PHP_VERSION`.
- docker-socket-proxy raised from 0.3.0 to v0.5.0 (HAProxy 3).
- ofelia `latest` digest refreshed.

### Fixed

- nginx kept its PID file on a tmpfs over `/var/run`, which is `/run`. Depending
  on the order in which the Docker engine applies the mounts, that tmpfs covered
  the php-fpm socket volume at `/run/php-fpm`, and every PHP request returned
  502 (seen on Docker 29.8). The tmpfs now covers only `/run/nginx`.

### Security

- Bundled GLPI bumped from 11.0.8 to 11.0.9, a security release: ten high-severity
  fixes, among them an unauthenticated SQL injection in the planning feature, an MFA
  bypass, stored XSS in ticket actors and asset names, and a marketplace race that
  allowed installing a malicious plugin.
  Release notes: https://github.com/glpi-project/glpi/releases/tag/11.0.9
