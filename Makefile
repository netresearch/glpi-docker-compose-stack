# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Netresearch DTT GmbH

SHELL := /bin/bash
.DEFAULT_GOAL := help

# ────────────────────────────────────────────────────────────────────
# Lifecycle
# ────────────────────────────────────────────────────────────────────

help: ## Show this help
	@printf 'glpi-docker-compose-stack — make targets\n\nUsage: make <target>\n\n'
	@awk 'BEGIN {FS = ":.*?##"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

init: ## Bootstrap .env (random DB passwords, idempotent)
	@./bin/init.sh

up: .env ## Start the stack (detached)
	docker compose up -d

# Guard: bringing the stack up without a populated .env poisons the db-data
# volume with an empty MARIADB_ROOT_PASSWORD that survives `make clean`.
# This rule fails before docker compose sees the empty env vars.
.env:
	@printf '\033[1;31m[make]\033[0m No .env found — run `make init` first.\n' >&2
	@exit 1

down: ## Stop the stack (preserves volumes)
	docker compose down

restart: ## Restart app + web only
	docker compose restart app web

logs: ## Tail logs (all services)
	docker compose logs -f --tail=100

logs-app: ## Tail logs (app service)
	docker compose logs -f --tail=100 app

ps: ## Show container status
	docker compose ps

# ────────────────────────────────────────────────────────────────────
# Overlays & integrations
# ────────────────────────────────────────────────────────────────────
#
# Overlay state lives in .env as COMPOSE_FILE=<colon-separated paths>.
# docker compose reads this automatically, so `make up` works without
# manual `-f` chaining once an overlay is enabled.

overlays: .env ## Show currently-enabled compose overlays
	@./bin/compose-file.sh list

enable-traefik: .env ## Add Traefik reverse-proxy overlay (TLS termination + label-based routing)
	@./bin/compose-file.sh add examples/compose.traefik.yml
	@printf '\033[1;34m[next]\033[0m Set GLPI_HOST in .env to your public hostname (e.g. glpi.example.com), then `make up`. Requires an existing `traefik` external network.\n'

disable-traefik: .env ## Remove Traefik overlay
	@./bin/compose-file.sh remove examples/compose.traefik.yml

enable-caddy: .env ## Add Caddy reverse-proxy overlay (TLS termination + auto-HTTPS)
	@./bin/compose-file.sh add examples/compose.caddy.yml
	@printf '\033[1;34m[next]\033[0m Set GLPI_HOST in .env to your public hostname (e.g. glpi.example.com), then `make up`.\n'

disable-caddy: .env ## Remove Caddy overlay
	@./bin/compose-file.sh remove examples/compose.caddy.yml

enable-observability: .env ## Add Prometheus + Grafana overlay (MariaDB + nginx metrics)
	@./bin/compose-file.sh add examples/compose.observability.yml
	@printf '\033[1;34m[next]\033[0m The nginx /stub_status endpoint is NOT enabled by default — see the overlay header for the two opt-in paths.\n'

disable-observability: .env ## Remove observability overlay
	@./bin/compose-file.sh remove examples/compose.observability.yml

# ────────────────────────────────────────────────────────────────────
# Backup / restore
# ────────────────────────────────────────────────────────────────────

backup-up: .env ## Start the opt-in backup service (phpbu, behind the `backup` profile)
	docker compose --profile backup up -d backup

backup: ## Run a backup now (requires `make backup-up`; normally ofelia at 03:00)
	docker compose --profile backup exec -T backup phpbu --configuration=/config/backup.json

backup-list: ## List backup archives
	docker compose --profile backup exec -T backup ls -lh /backups

backup-verify: ## Sanity-check that last night's backup is on disk + non-zero
	@docker compose --profile backup exec -T backup sh -c '\
		latest=$$(ls -t /backups/db/*.sql.gz 2>/dev/null | head -1); \
		if [ -z "$$latest" ]; then \
			echo "✗ no DB backups in /backups/db"; exit 1; \
		fi; \
		size=$$(stat -c%s "$$latest"); \
		age_h=$$(( ($$(date +%s) - $$(stat -c%Y "$$latest")) / 3600 )); \
		if [ "$$size" -lt 1024 ]; then \
			echo "✗ $$latest is $$size bytes — likely empty"; exit 1; \
		fi; \
		if [ "$$age_h" -gt 26 ]; then \
			echo "✗ newest dump is $${age_h}h old (should be < 26h)"; exit 1; \
		fi; \
		echo "✓ newest dump $$latest ($$size bytes, $${age_h}h old)"'

health: ## Aggregated health state of all services + non-healthy summary
	@docker compose ps --format '{{.Service}}\t{{.Status}}' | column -ts $$'\t'
	@unhealthy=$$(docker compose ps --filter "health=unhealthy" -q | wc -l | tr -d ' '); \
	if [ "$$unhealthy" != "0" ]; then \
		printf '\n\033[1;31m%s unhealthy service(s)\033[0m — see docker compose logs <service>\n' "$$unhealthy"; \
		exit 1; \
	else \
		printf '\n\033[1;32mAll services healthy.\033[0m\n'; \
	fi

# ────────────────────────────────────────────────────────────────────
# Testing (local)
# ────────────────────────────────────────────────────────────────────

test-image: ## Build runtime image + run container-structure-test (image-surface check)
	docker buildx build --target runtime --platform linux/amd64 --load -t glpi-php-fpm:test .
	@command -v container-structure-test >/dev/null 2>&1 \
	  || { echo "Install: https://github.com/GoogleContainerTools/container-structure-test/releases"; exit 1; }
	container-structure-test test --image glpi-php-fpm:test --config tests/container-structure-test.yaml

test-bats: ## Run bats regression suite for bin/ helpers (uses bats/bats Docker image — no local install)
	docker run --rm -v "$(CURDIR)":/code -w /code bats/bats:latest tests/bin/

hardening-check: ## Assert every overlay keeps no-new-privileges + cap_drop:[ALL] (tests/lint/hardening-check.sh)
	./tests/lint/hardening-check.sh

test: test-image test-bats hardening-check ## Run the local test suite (image surface + bats + overlay hardening)

# ────────────────────────────────────────────────────────────────────
# Dev convenience
# ────────────────────────────────────────────────────────────────────

dev: ## Seed compose.override.yml from the example (if missing) + `make up`
	@if [ ! -f compose.override.yml ]; then \
		cp compose.override.yml.example compose.override.yml; \
		printf '\033[1;34m[make]\033[0m seeded compose.override.yml from example\n'; \
	else \
		printf '\033[1;34m[make]\033[0m compose.override.yml already present — keeping\n'; \
	fi
	$(MAKE) up

build: ## Build the runtime image locally (glpi-php-fpm:local, supply-chain-pinned) — no push
	@v=$$(tr -d '[:space:]' < .glpi-version); \
	url="https://github.com/glpi-project/glpi/releases/download/$$v/glpi-$$v.tgz"; \
	printf '\033[1;34m[build]\033[0m resolving sha256 of %s\n' "$$url"; \
	sha=$$(curl -fsSL "$$url" | sha256sum | cut -d' ' -f1); \
	[ -n "$$sha" ] || { printf '\033[1;31m[build]\033[0m could not hash %s\n' "$$url" >&2; exit 1; }; \
	printf '\033[1;34m[build]\033[0m GLPI %s  sha256=%s\n' "$$v" "$$sha"; \
	docker buildx build --target runtime --platform linux/amd64 --load \
		-t glpi-php-fpm:local \
		--build-arg GLPI_VERSION="$$v" \
		--build-arg GLPI_SHA256="$$sha" .

lint: ## Run hadolint + shellcheck + yamllint via Docker (no local install)
	@printf '\033[1;34m[lint]\033[0m hadolint Dockerfile\n'
	docker run --rm -i -v $(CURDIR):/work -w /work \
		hadolint/hadolint:latest-alpine \
		hadolint --config .hadolint.yaml Dockerfile
	@printf '\033[1;34m[lint]\033[0m shellcheck rootfs/usr/local/bin + bin\n'
	docker run --rm -v $(CURDIR):/work -w /work \
		koalaman/shellcheck:stable \
		$$(find rootfs/usr/local/bin bin -type f \( -name '*.sh' -o -perm -u+x \) 2>/dev/null)
	@printf '\033[1;34m[lint]\033[0m yamllint compose + workflows\n'
	docker run --rm -v $(CURDIR):/work -w /work \
		cytopia/yamllint:1 \
		-d "{extends: default, rules: {line-length: disable, document-start: disable, truthy: {check-keys: false}, comments: {min-spaces-from-content: 1}}}" \
		.github/workflows .hadolint.yaml compose.yml
	@printf '\033[1;34m[lint]\033[0m actionlint .github/workflows\n'
	docker run --rm -v $(CURDIR):/work -w /work \
		rhysd/actionlint:latest -color

# ────────────────────────────────────────────────────────────────────
# Upgrade
# ────────────────────────────────────────────────────────────────────

pull: ## Pull latest images
	docker compose pull

upgrade: pull up logs-app ## Pull + recreate + follow logs

# ────────────────────────────────────────────────────────────────────
# Maintenance
# ────────────────────────────────────────────────────────────────────

shell: ## Shell into the app container
	docker compose exec app sh

console: ## Run a GLPI console command (use: make console CMD="cache:configure --help")
	docker compose exec -u www-data app php bin/console $(CMD)

restore: ## Print pointer to the disaster-recovery runbook (not automated)
	@printf '\033[1;33m[restore]\033[0m This target intentionally does NOT automate restore.\n'
	@printf '         Restoring is destructive and context-specific — follow the\n'
	@printf '         runbook step by step:\n\n'
	@printf '           docs/runbook-restore.md\n\n'
	@printf '         TL;DR: stop app+scheduler, pick a dump from the backups volume,\n'
	@printf '         drop+recreate the database, gunzip | mariadb, restore the\n'
	@printf '         files/ and config/ tarballs, then `make restart`.\n'

clean: ## DESTRUCTIVE: down + delete ALL volumes (db + uploads + backups)
	@read -r -p "This deletes ALL data — the database, uploads AND the backups volume. Type 'yes' to proceed: " ans; \
	  [ "$$ans" = "yes" ] || { echo "aborted"; exit 1; }
	docker compose down -v

.PHONY: \
	help init up down restart logs logs-app ps \
	backup backup-up backup-list backup-verify \
	health test test-image test-bats hardening-check \
	dev build lint pull upgrade \
	shell console restore clean \
	overlays \
	enable-traefik disable-traefik \
	enable-caddy disable-caddy \
	enable-observability disable-observability
