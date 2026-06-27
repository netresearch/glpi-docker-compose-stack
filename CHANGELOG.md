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
  (vendor/ already included — no Composer step), on PHP 8.4 / Alpine 3.21, with
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
  daily Trivy and osv-scanner scanning, OpenSSF Scorecard, and a lint suite
  (hadolint, shellcheck, yamllint, actionlint) plus bats and smoke tests.
  - `docker-bake.hcl` and a tag-triggered `release.yml` that builds, signs and
    publishes the canonical tag set (`<version>`, `<major.minor>`, `<major>`,
    `latest`); a weekly GHCR retention job prunes untagged versions.
- **Automated updates** via Renovate (base images, PHP packages, GLPI version
  pin) with Dependabot covering GitHub Actions.
- **Documentation**: README, migration guide, day-2 operations and restore
  runbooks, plus the standard community files (CONTRIBUTING, CODE_OF_CONDUCT,
  SECURITY) and a `pre-commit` configuration mirroring the CI lint gate.
