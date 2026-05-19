SHELL := /bin/bash

# Compose stack definitions.
COMPOSE_BASE       := -f docker-compose.yml
COMPOSE_PRIVACY    := $(COMPOSE_BASE) -f docker-compose.privacy.yml
COMPOSE_FOOD       := $(COMPOSE_PRIVACY) -f docker-compose.food.yml
COMPOSE_LOCAL      := $(COMPOSE_PRIVACY) -f docker-compose.local.yml
# Admin overlay sits on top of the main stack (shares postgres/redis).
COMPOSE_ADMIN      := $(COMPOSE_PRIVACY) -f docker-compose.admin.yml
# Admin in local (SQLite) mode — for dev / lightweight ops without Postgres.
# IMPORTANT: local.yml MUST load AFTER admin.yml so its `admin-service:
# depends_on: !reset []` overrides admin.yml's postgres dependency. Compose
# merges later files on top of earlier ones.
COMPOSE_ADMIN_LOCAL := $(COMPOSE_PRIVACY) -f docker-compose.admin.yml -f docker-compose.local.yml
# Admin + Web overlay (Next.js console).
COMPOSE_ADMIN_WEB  := $(COMPOSE_ADMIN) -f docker-compose.admin-web.yml
# Admin + Web in local (SQLite) mode (same order rule).
COMPOSE_ADMIN_WEB_LOCAL := $(COMPOSE_ADMIN_LOCAL) -f docker-compose.admin-web.yml
# Admin standalone is a self-contained compose file (no base merge).
COMPOSE_STANDALONE := -f docker-compose.admin-standalone.yml
# Standalone + Web (Web is reusable as overlay).
COMPOSE_STANDALONE_WEB := $(COMPOSE_STANDALONE) -f docker-compose.admin-web.yml

.PHONY: help \
        up-p1 up-p1-p2 up-local \
        up-admin up-p1-admin up-admin-only \
        up-admin-local up-admin-web-local \
        up-admin-web up-admin-web-only up-admin-standalone-web \
        up-admin-standalone up-admin-standalone-db \
        restart-admin restart-admin-web \
        down down-local down-admin down-admin-only \
        down-admin-local down-admin-web-local \
        down-admin-web down-admin-web-only down-admin-standalone \
        logs admin-logs admin-web-logs admin-standalone-logs \
        ps ps-admin ps-standalone \
        build rebuild build-admin build-admin-web \
        psql redis-cli \
        smoke smoke-admin smoke-admin-web smoke-admin-standalone \
        test clean

help:
	@echo "── Main stack ────────────────────────────────────────────────"
	@echo "  up-p1                    Postgres + Redis + Phase 1 (privacy)."
	@echo "  up-p1-p2                 Phase 1 + Phase 2 (food) [stub]."
	@echo "  up-local                 SQLite-only mode (no Postgres / Redis)."
	@echo "  down                     Stop and remove main-stack containers."
	@echo "  down-local               Stop and remove SQLite-mode containers."
	@echo "── Admin co-located (overlay on main stack) ──────────────────"
	@echo "  up-admin                 main stack + Admin API (alias up-p1-admin)."
	@echo "  up-p1-admin              Same as up-admin."
	@echo "  up-admin-only            Only (re)start admin-service (no other svc)."
	@echo "  restart-admin            Restart only admin-service."
	@echo "  down-admin               Stop ALL containers including admin."
	@echo "  down-admin-only          Stop ONLY the admin-service container."
	@echo "  up-admin-local           Admin in SQLite mode (no Postgres)."
	@echo "  down-admin-local         Stop SQLite-mode Admin stack."
	@echo "── Admin Web (Next.js console) ───────────────────────────────"
	@echo "  up-admin-web-local       Admin + Web in SQLite mode (lightest)."
	@echo "  down-admin-web-local     Stop SQLite Admin + Web stack."
	@echo "  up-admin-web             main stack + Admin API + Admin Web (3001)."
	@echo "  up-admin-web-only        Only (re)start admin-web container."
	@echo "  restart-admin-web        Restart only admin-web."
	@echo "  down-admin-web           Stop ALL containers including admin + web."
	@echo "  down-admin-web-only      Stop ONLY the admin-web container."
	@echo "  up-admin-standalone-web  Standalone Admin + Web (own host / VPN)."
	@echo "── Admin standalone (separate host / network) ────────────────"
	@echo "  up-admin-standalone      Standalone Admin, external DB via env."
	@echo "  up-admin-standalone-db   Standalone Admin + bundled Postgres (port 5433)."
	@echo "  down-admin-standalone    Stop standalone Admin stack."
	@echo "── Diagnostics / smoke ──────────────────────────────────────"
	@echo "  logs / admin-logs / admin-web-logs / admin-standalone-logs"
	@echo "  ps  / ps-admin / ps-standalone"
	@echo "  smoke                    MCP HTTP smoke."
	@echo "  smoke-admin              /admin/health on the co-located admin."
	@echo "  smoke-admin-web          /login on the admin-web console."
	@echo "  smoke-admin-standalone   /admin/health on the standalone admin."
	@echo "── Build / data plane ───────────────────────────────────────"
	@echo "  build / rebuild / build-admin / build-admin-web"
	@echo "  psql / redis-cli / test / clean"

# ─────────────────────────────────────────────────────────────────────
# Main stack
# ─────────────────────────────────────────────────────────────────────
up-p1:
	docker compose $(COMPOSE_PRIVACY) up -d

up-p1-p2:
	docker compose $(COMPOSE_FOOD) up -d

up-local:
	docker compose $(COMPOSE_LOCAL) up -d

down:
	docker compose $(COMPOSE_BASE) down

down-local:
	docker compose $(COMPOSE_LOCAL) down -v

# ─────────────────────────────────────────────────────────────────────
# Admin co-located
# ─────────────────────────────────────────────────────────────────────
up-admin: up-p1-admin
up-p1-admin:
	docker compose $(COMPOSE_ADMIN) up -d

# Start ONLY admin-service in the existing main stack.
up-admin-only:
	docker compose $(COMPOSE_ADMIN) up -d --no-deps admin-service

restart-admin:
	docker compose $(COMPOSE_ADMIN) restart admin-service

down-admin:
	docker compose $(COMPOSE_ADMIN) down

down-admin-only:
	docker compose $(COMPOSE_ADMIN) stop admin-service
	docker compose $(COMPOSE_ADMIN) rm -f admin-service

# Admin in SQLite (local) mode — no Postgres, no Redis, single-host.
# Combines privacy + local + admin overlays so admin-service picks up
# DB_DRIVER=sqlite and the disabled postgres profile.
up-admin-local:
	docker compose $(COMPOSE_ADMIN_LOCAL) up -d

down-admin-local:
	docker compose $(COMPOSE_ADMIN_LOCAL) down -v

# Admin + Web in SQLite mode — the lightest fully-featured stack
# (postgres / redis are both off, admin DB is /app/var/admin.db, web on 3001).
up-admin-web-local:
	docker compose $(COMPOSE_ADMIN_WEB_LOCAL) up -d

down-admin-web-local:
	docker compose $(COMPOSE_ADMIN_WEB_LOCAL) down -v

# ─────────────────────────────────────────────────────────────────────
# Admin Web (Next.js)
# ─────────────────────────────────────────────────────────────────────
up-admin-web:
	docker compose $(COMPOSE_ADMIN_WEB) up -d

# (Re)start only admin-web. Other services stay untouched.
up-admin-web-only:
	docker compose $(COMPOSE_ADMIN_WEB) up -d --no-deps admin-web

restart-admin-web:
	docker compose $(COMPOSE_ADMIN_WEB) restart admin-web

down-admin-web:
	docker compose $(COMPOSE_ADMIN_WEB) down

down-admin-web-only:
	docker compose $(COMPOSE_ADMIN_WEB) stop admin-web
	docker compose $(COMPOSE_ADMIN_WEB) rm -f admin-web

# Standalone Admin + Web, talking to external Policy Engine via ENV.
up-admin-standalone-web:
	docker compose $(COMPOSE_STANDALONE_WEB) up -d

# ─────────────────────────────────────────────────────────────────────
# Admin standalone
# ─────────────────────────────────────────────────────────────────────
up-admin-standalone:
	docker compose $(COMPOSE_STANDALONE) up -d admin-service

up-admin-standalone-db:
	docker compose $(COMPOSE_STANDALONE) --profile with-db up -d

down-admin-standalone:
	docker compose $(COMPOSE_STANDALONE) --profile with-db down -v

# ─────────────────────────────────────────────────────────────────────
# Diagnostics
# ─────────────────────────────────────────────────────────────────────
logs:
	docker compose $(COMPOSE_BASE) logs -f --tail=200

admin-logs:
	docker compose $(COMPOSE_ADMIN) logs -f --tail=200 admin-service

admin-web-logs:
	docker compose $(COMPOSE_ADMIN_WEB) logs -f --tail=200 admin-web

admin-standalone-logs:
	docker compose $(COMPOSE_STANDALONE) logs -f --tail=200 admin-service

ps:
	docker compose $(COMPOSE_BASE) ps

ps-admin:
	docker compose $(COMPOSE_ADMIN) ps

ps-standalone:
	docker compose $(COMPOSE_STANDALONE) ps

# ─────────────────────────────────────────────────────────────────────
# Build
# ─────────────────────────────────────────────────────────────────────
build:
	docker compose $(COMPOSE_BASE) build

rebuild:
	docker compose $(COMPOSE_BASE) build --no-cache

build-admin:
	docker compose $(COMPOSE_ADMIN) build admin-service

build-admin-web:
	docker compose $(COMPOSE_ADMIN_WEB) build admin-web

# ─────────────────────────────────────────────────────────────────────
# Smoke
# ─────────────────────────────────────────────────────────────────────
smoke:
	@bash ./scripts/smoke.sh

smoke-admin:
	@curl -fsS http://localhost:$${ADMIN_EXPOSED_PORT:-8084}/admin/health | (jq . 2>/dev/null || cat)

smoke-admin-web:
	@curl -fsS -o /dev/null -w "HTTP %{http_code}\n" http://localhost:$${ADMIN_WEB_EXPOSED_PORT:-3001}/login

smoke-admin-standalone:
	@curl -fsS http://localhost:$${ADMIN_EXPOSED_PORT:-8084}/admin/health | (jq . 2>/dev/null || cat)

# ─────────────────────────────────────────────────────────────────────
# Misc
# ─────────────────────────────────────────────────────────────────────
psql:
	docker compose $(COMPOSE_BASE) exec postgres psql -U $${POSTGRES_USER:-guardrails} -d $${POSTGRES_DB:-guardrails}

redis-cli:
	docker compose $(COMPOSE_BASE) exec redis redis-cli

test:
	@echo "Run per-service tests under their own directories."
	@echo "  Server         : cd ../Guardrails-Service-Server         && npm test"
	@echo "  Policy-Engine  : cd ../Guardrails-Service-Policy-Engine  && npm test"
	@echo "  Audit-Service  : cd ../Guardrails-Service-Audit-Service  && npm test"
	@echo "  Admin          : cd ../Guardrails-Service-Admin          && npm test"
	@echo "  Admin-Web      : cd ../Guardrails-Service-Admin-Web      && npm run build (smoke)"
	@echo "  Detection-Eng. : cd ../../DA(Python,R,...)/Guardrails-Service-Detection-Engine && pytest"

clean:
	docker compose $(COMPOSE_BASE) down -v --remove-orphans
	-docker compose $(COMPOSE_STANDALONE) --profile with-db down -v --remove-orphans
