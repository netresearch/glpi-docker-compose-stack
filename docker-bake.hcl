# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Netresearch DTT GmbH
#
# docker-bake.hcl — build configuration for the glpi-php-fpm image.
#
# Usage:
#   docker buildx bake                 # build the default group (multi-arch)
#   docker buildx bake glpi            # build the release target explicitly
#   docker buildx bake dev             # single-arch, loaded into the local docker
#   docker buildx bake --print         # validate + show the resolved plan
#
# Reference: https://docs.docker.com/build/bake/
#
# This file is the single source of truth for the *release* build:
# .github/workflows/release.yml feeds it GLPI_VERSION / GLPI_SHA256 / BUILD_DATE
# / GIT_SHA from the pushed release tag, then pushes + cosign-signs the result.
# The day-to-day CI rebuild (build.yml / _build-cell.yml) drives docker buildx
# build directly for its per-arch digest fan-out; this bake file deliberately
# stays simple and is what humans and the release workflow use.
#
# Unlike the Snipe-IT sibling there is NO minimal/full split and NO composer
# "rolling" variant: GLPI ships a bundled release tarball (vendor/ included), so
# there is exactly one image. The GLPI-appropriate equivalent of "rolling" is
# the daily rebuild of the floating tags against a fresh Alpine/PHP base.

# ── Variables (override via env or --set) ────────────────────────────────────

# Container registry. Combined with REPO to form the full image reference
# ghcr.io/netresearch/glpi-php-fpm.
variable "REGISTRY" {
  default = "ghcr.io"
}

# Image repository (owner/name), WITHOUT the registry host. Full published
# reference is "${REGISTRY}/${REPO}" = ghcr.io/netresearch/glpi-php-fpm.
variable "REPO" {
  default = "netresearch/glpi-php-fpm"
}

# GLPI release bundled into the image — keep in sync with .glpi-version.
# GLPI release tags carry NO 'v' prefix (e.g. 11.0.8).
variable "GLPI_VERSION" {
  default = "11.0.8"
}

# GLPI major.minor + major, DERIVED from GLPI_VERSION so only GLPI_VERSION
# (and .glpi-version / the Dockerfile ARG) needs bumping — no drift.
variable "GLPI_MINOR" {
  default = regex_replace(GLPI_VERSION, "^([0-9]+\\.[0-9]+)\\..*$", "$1")
}
variable "GLPI_MAJOR" {
  default = regex_replace(GLPI_VERSION, "^([0-9]+)\\..*$", "$1")
}

# sha256 of glpi-${GLPI_VERSION}.tgz — supply-chain pin passed straight to the
# Dockerfile's fetch stage. Empty by default so a bare `docker buildx bake`
# works offline-of-CI; release.yml resolves and injects the real digest so a
# swapped release asset cannot slip into a signed image.
variable "GLPI_SHA256" {
  default = ""
}

# RFC-3339 build timestamp — surfaces as org.opencontainers.image.created.
# Empty by default (a reproducible local build shouldn't bake a wall-clock).
variable "BUILD_DATE" {
  default = ""
}

# Git commit SHA of this repo at build time — surfaces as
# org.opencontainers.image.revision (the Dockerfile's VCS_REF arg).
variable "GIT_SHA" {
  default = ""
}

# ── Groups ───────────────────────────────────────────────────────────────────

# Default group: the single GLPI image. `docker buildx bake` with no target
# builds this.
group "default" {
  targets = ["glpi"]
}

# ── Targets ──────────────────────────────────────────────────────────────────

# glpi — the release artifact. Multi-arch, attested, pushed by release.yml.
target "glpi" {
  context    = "."
  dockerfile = "Dockerfile"
  # Build the php-fpm runtime stage (the fetch stage is an internal build stage).
  target = "runtime"

  # Native multi-arch. release.yml installs QEMU so a single bake call can emit
  # both arches; the daily CI rebuild uses native per-arch runners instead.
  platforms = [
    "linux/amd64",
    "linux/arm64",
  ]

  # Build args consumed by the Dockerfile. GLPI_VERSION drives the tarball
  # download; GLPI_SHA256 pins its integrity; BUILD_DATE / VCS_REF populate the
  # created / revision OCI labels declared in the Dockerfile.
  args = {
    GLPI_VERSION = "${GLPI_VERSION}"
    GLPI_SHA256  = "${GLPI_SHA256}"
    BUILD_DATE   = "${BUILD_DATE}"
    VCS_REF      = "${GIT_SHA}"
  }

  # Canonical tag set: <version>, <major.minor>, <major>, latest. No dated or
  # sha-suffixed tags here — release.yml is invoked once per immutable release
  # tag, and the daily build.yml owns the moving dated/sha snapshots.
  tags = [
    "${REGISTRY}/${REPO}:${GLPI_VERSION}",
    "${REGISTRY}/${REPO}:${GLPI_MINOR}",
    "${REGISTRY}/${REPO}:${GLPI_MAJOR}",
    "${REGISTRY}/${REPO}:latest",
  ]

  # OCI labels. Mirror the Dockerfile's LABEL block (bake wins on conflict) so
  # the image is self-describing regardless of build entry point.
  # licenses = GPL-3.0-or-later: that is the license of the *bundled GLPI*
  # application you receive in this image. (This repo's own packaging code is
  # MIT and its docs are CC-BY-SA-4.0 — see LICENSE-MIT / LICENSE-CC-BY-SA-4.0.)
  labels = {
    "org.opencontainers.image.title"         = "glpi-php-fpm"
    "org.opencontainers.image.description"    = "GLPI ${GLPI_VERSION} on PHP / Alpine — php-fpm only (use with glpi-docker-compose-stack)"
    "org.opencontainers.image.url"            = "https://github.com/netresearch/glpi-docker-compose-stack"
    "org.opencontainers.image.source"         = "https://github.com/netresearch/glpi-docker-compose-stack"
    "org.opencontainers.image.documentation"  = "https://github.com/netresearch/glpi-docker-compose-stack#readme"
    "org.opencontainers.image.vendor"         = "Netresearch DTT GmbH"
    "org.opencontainers.image.licenses"       = "GPL-3.0-or-later"
    "org.opencontainers.image.version"        = "${GLPI_VERSION}"
    "org.opencontainers.image.created"        = "${BUILD_DATE}"
    "org.opencontainers.image.revision"       = "${GIT_SHA}"
  }

  # Supply-chain attestations: SLSA provenance (max) + an in-image SBOM.
  attest = [
    "type=provenance,mode=max",
    "type=sbom",
  ]

  # GitHub Actions layer cache. release.yml may override the scope via --set.
  cache-from = ["type=gha,scope=glpi"]
  cache-to   = ["type=gha,scope=glpi,mode=max"]
}

# dev — fast local iteration: host arch only, loaded straight into `docker
# images` (no push, no attestations). `docker buildx bake dev` then
# `docker run --rm glpi-php-fpm:dev php -v`. Inherits the release target's
# context/args so it builds the same code with the same defaults.
target "dev" {
  inherits  = ["glpi"]
  platforms = ["linux/amd64"]
  tags      = ["glpi-php-fpm:dev"]
  # No registry push and no attestations for a throwaway local image.
  attest = []
  output = ["type=docker"]
  # The GHA cache backend needs ACTIONS_* tokens that don't exist locally.
  cache-from = []
  cache-to   = []
}
