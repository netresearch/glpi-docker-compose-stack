# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Netresearch DTT GmbH

SHELL := /bin/bash
.DEFAULT_GOAL := help

# ────────────────────────────────────────────────────────────────────
# Lifecycle
# ────────────────────────────────────────────────────────────────────

help: ## Show this help
	@awk 'BEGIN {FS = ":.*?##"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

init: ## Bootstrap .env (APP_KEY + random DB passwords, idempotent)
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

enable-bugsink: .env ## Add self-hosted Bugsink overlay (in-stack error tracking, auto-DSN)
	@./bin/compose-file.sh add examples/compose.bugsink.yml
	@if grep -qE '^SENTRY_LARAVEL_DSN=.+$$' .env; then \
	  printf '\033[1;33m[warn]\033[0m SENTRY_LARAVEL_DSN is set — the bugsink-init container will override it with the in-stack DSN.\n'; \
	fi
	@printf '\033[1;34m[next]\033[0m Fill BUGSINK_SECRET_KEY (openssl rand -base64 50), BUGSINK_ADMIN_EMAIL, BUGSINK_ADMIN_PASSWORD in .env, then `make up`.\n'

disable-bugsink: .env ## Remove Bugsink overlay (BUGSINK_* env vars stay in .env)
	@./bin/compose-file.sh remove examples/compose.bugsink.yml

enable-sentry: .env ## Point error tracking at an external Sentry/Bugsink DSN. Usage: make enable-sentry DSN=https://...
	@test -n "$(DSN)" || { printf '\033[1;31m[err]\033[0m Usage: make enable-sentry DSN=https://...\n' >&2; exit 1; }
	@if ./bin/compose-file.sh list | grep -q '^examples/compose.bugsink.yml$$'; then \
	  printf '\033[1;33m[warn]\033[0m bugsink overlay is enabled — its init container auto-seeds the DSN; this manual DSN will be ignored.\n'; \
	fi
	@./bin/env-set.sh SENTRY_LARAVEL_DSN "$(DSN)"

disable-sentry: .env ## Clear SENTRY_LARAVEL_DSN (turns external error reporting off)
	@./bin/env-set.sh SENTRY_LARAVEL_DSN ""

enable-traefik: .env ## Add Traefik reverse-proxy overlay (TLS termination + label-based routing)
	@./bin/compose-file.sh add examples/compose.traefik.yml
	@printf '\033[1;34m[next]\033[0m Set SNIPEIT_HOST in .env to your public hostname (e.g. glpi.example.com), then `make up`. Requires an existing `traefik` external network.\n'

disable-traefik: .env ## Remove Traefik overlay
	@./bin/compose-file.sh remove examples/compose.traefik.yml

enable-caddy: .env ## Add Caddy reverse-proxy overlay (TLS termination + auto-HTTPS)
	@./bin/compose-file.sh add examples/compose.caddy.yml
	@printf '\033[1;34m[next]\033[0m Set SNIPEIT_HOST in .env to your public hostname (e.g. glpi.example.com), then `make up`.\n'

disable-caddy: .env ## Remove Caddy overlay
	@./bin/compose-file.sh remove examples/compose.caddy.yml

enable-observability: .env ## Add Prometheus + exporters overlay (php-fpm + nginx metrics)
	@./bin/compose-file.sh add examples/compose.observability.yml
	@printf '\033[1;34m[next]\033[0m The nginx /stub_status endpoint is NOT enabled by default — see the overlay header for the two opt-in paths.\n'

disable-observability: .env ## Remove observability overlay
	@./bin/compose-file.sh remove examples/compose.observability.yml

# ────────────────────────────────────────────────────────────────────
# Backup / restore
# ────────────────────────────────────────────────────────────────────

backup: ## Run a backup now (normally scheduled by ofelia at 03:00)
	docker compose exec -T backup phpbu --configuration=/config/backup.json

backup-list: ## List backup archives
	docker compose exec -T backup ls -lh /backups

backup-verify: ## Sanity-check that last night's backup is on disk + non-zero
	@docker compose exec -T backup sh -c '\
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

test-glpi: ## Build tester stage — runs GLPI's own phpunit suite, fails the build on any failure
	docker buildx build --target tester --platform linux/amd64 .

test-bats: ## Run bats regression suite for bin/ helpers (uses bats/bats Docker image — no local install)
	docker run --rm -v "$(CURDIR)":/code -w /code bats/bats:latest tests/bin/

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

build: ## Build the runtime image locally (glpi-php-fpm:local) — no push
	docker buildx build --target runtime --platform linux/amd64 --load \
		-t glpi-php-fpm:local \
		--build-arg GLPI_VERSION=$$(cat .glpi-version) .

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

artisan: ## Run an artisan command (use: make artisan CMD="route:list")
	docker compose exec app php /var/www/html/artisan $(CMD)

tinker: ## Open an interactive REPL inside the app container (php artisan tinker)
	docker compose exec app php /var/www/html/artisan tinker

restore: ## Print pointer to the disaster-recovery runbook (not automated)
	@printf '\033[1;33m[restore]\033[0m This target intentionally does NOT automate restore.\n'
	@printf '         Restoring is destructive and context-specific — follow the\n'
	@printf '         runbook step by step:\n\n'
	@printf '           docs/runbook-restore.md\n\n'
	@printf '         TL;DR: stop app+scheduler, pick a dump from the backups volume,\n'
	@printf '         drop+recreate the database, gunzip | mariadb, restore uploads/\n'
	@printf '         and storage/ tarballs, then `make restart`.\n'

clean: ## DESTRUCTIVE: down + delete ALL volumes (db + uploads + backups)
	@read -r -p "This deletes ALL data — the database, uploads AND the backups volume. Type 'yes' to proceed: " ans; \
	  [ "$$ans" = "yes" ] || { echo "aborted"; exit 1; }
	docker compose down -v

.PHONY: \
	help init up down restart logs logs-app ps \
	backup backup-list backup-verify \
	health test-image test-glpi \
	dev build lint pull upgrade \
	shell artisan tinker restore clean \
	overlays \
	enable-bugsink disable-bugsink \
	enable-sentry disable-sentry \
	enable-traefik disable-traefik \
	enable-caddy disable-caddy \
	enable-observability disable-observability
