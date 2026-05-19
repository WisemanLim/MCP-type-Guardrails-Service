SHELL := /bin/bash

# ─────────────────────────────────────────────────────────────────────
# Compose file building blocks
# ─────────────────────────────────────────────────────────────────────
COMPOSE_BASE    := -f docker-compose.yml
COMPOSE_PRIVACY := $(COMPOSE_BASE) -f docker-compose.privacy.yml
COMPOSE_FOOD    := $(COMPOSE_PRIVACY) -f docker-compose.food.yml

# Overlay fragments
COMPOSE_LOCAL_OV       := -f docker-compose.local.yml
COMPOSE_ADMIN_OV       := -f docker-compose.admin.yml
COMPOSE_ADMIN_LOCAL_OV := -f docker-compose.admin-local.yml
COMPOSE_WEB_OV         := -f docker-compose.admin-web.yml
COMPOSE_STANDALONE     := -f docker-compose.admin-standalone.yml

# ─────────────────────────────────────────────────────────────────────
# Production stacks (postgres + redis)
# ─────────────────────────────────────────────────────────────────────
# p1            = phase 1 (privacy)
# p1-p2         = + phase 2 (food)
# p1-admin      = + Admin API
# p1-admin-web  = + Admin API + Admin Web Console
COMPOSE_P1            := $(COMPOSE_PRIVACY)
COMPOSE_P1_P2         := $(COMPOSE_FOOD)
COMPOSE_P1_ADMIN      := $(COMPOSE_P1)     $(COMPOSE_ADMIN_OV)
COMPOSE_P1_ADMIN_WEB  := $(COMPOSE_P1_ADMIN) $(COMPOSE_WEB_OV)

# ─────────────────────────────────────────────────────────────────────
# Local stacks (sqlite, no postgres/redis)
#
# CRITICAL ORDER: local.yml MUST load LAST so its admin-service
# `depends_on: !reset []` overrides admin.yml's postgres dependency.
# ─────────────────────────────────────────────────────────────────────
COMPOSE_P1_LOCAL            := $(COMPOSE_P1)            $(COMPOSE_LOCAL_OV)
COMPOSE_P1_P2_LOCAL         := $(COMPOSE_P1_P2)         $(COMPOSE_LOCAL_OV)
COMPOSE_P1_ADMIN_LOCAL      := $(COMPOSE_P1_ADMIN)      $(COMPOSE_LOCAL_OV) $(COMPOSE_ADMIN_LOCAL_OV)
COMPOSE_P1_ADMIN_WEB_LOCAL  := $(COMPOSE_P1_ADMIN_WEB)  $(COMPOSE_LOCAL_OV) $(COMPOSE_ADMIN_LOCAL_OV)

.PHONY: help \
        up-p1 up-p1-p2 \
        up-p1-local up-p1-p2-local \
        up-p1-admin up-p1-admin-web up-admin up-admin-web \
        up-p1-admin-local up-p1-admin-web-local up-admin-local up-admin-web-local \
        up-admin-only up-admin-web-only \
        up-admin-only-local up-admin-web-only-local \
        restart-admin restart-admin-web \
        up-admin-standalone up-admin-standalone-db up-admin-standalone-web \
        down down-local \
        down-p1-admin down-p1-admin-web \
        down-p1-admin-local down-p1-admin-web-local \
        down-admin down-admin-web down-admin-local down-admin-web-local \
        down-admin-only down-admin-web-only \
        down-admin-only-local down-admin-web-only-local \
        down-admin-standalone \
        logs admin-logs admin-web-logs admin-standalone-logs \
        ps ps-admin ps-admin-web ps-local ps-standalone \
        build rebuild build-admin build-admin-web \
        psql redis-cli \
        smoke smoke-admin smoke-admin-web smoke-admin-standalone \
        test clean

help:
	@echo "── PRODUCTION (postgres + redis) ────────────────────────────"
	@echo "  up-p1                       Phase 1 (privacy)."
	@echo "  up-p1-p2                    Phase 1 + Phase 2 (food)."
	@echo "  up-p1-admin (= up-admin)    Phase 1 + Admin API."
	@echo "  up-p1-admin-web (= up-admin-web)"
	@echo "                              Phase 1 + Admin API + Admin Web (3001)."
	@echo "  up-admin-only               (Re)create only admin-service in a"
	@echo "                              running production stack."
	@echo "  up-admin-web-only           (Re)create only admin-service +"
	@echo "                              admin-web in a running production stack."
	@echo ""
	@echo "── LOCAL (sqlite, no postgres/redis) ────────────────────────"
	@echo "  up-p1-local                 Phase 1 (privacy) in SQLite mode."
	@echo "  up-p1-p2-local              Phase 1 + Phase 2 (food) in SQLite."
	@echo "  up-p1-admin-local (= up-admin-local)"
	@echo "                              Phase 1 + Admin API in SQLite mode."
	@echo "  up-p1-admin-web-local (= up-admin-web-local)"
	@echo "                              Phase 1 + Admin API + Admin Web in SQLite."
	@echo "  up-admin-only-local         (Re)create only admin-service in a"
	@echo "                              running local stack."
	@echo "  up-admin-web-only-local     (Re)create only admin-service +"
	@echo "                              admin-web in a running local stack."
	@echo ""
	@echo "── STANDALONE (Admin lives on its own host / network) ───────"
	@echo "  up-admin-standalone         Standalone Admin, external DB via env."
	@echo "  up-admin-standalone-db      Standalone Admin + bundled Postgres (5433)."
	@echo "  up-admin-standalone-web     Standalone Admin + Web."
	@echo ""
	@echo "── DOWN (mirror of up-*) ────────────────────────────────────"
	@echo "  down / down-local"
	@echo "  down-p1-admin / down-p1-admin-web (= down-admin / down-admin-web)"
	@echo "  down-p1-admin-local / down-p1-admin-web-local"
	@echo "       (= down-admin-local / down-admin-web-local)"
	@echo "  down-admin-only / down-admin-web-only"
	@echo "  down-admin-only-local / down-admin-web-only-local"
	@echo "  down-admin-standalone"
	@echo ""
	@echo "── DIAGNOSTICS / SMOKE ──────────────────────────────────────"
	@echo "  logs / admin-logs / admin-web-logs / admin-standalone-logs"
	@echo "  ps / ps-admin / ps-admin-web / ps-local / ps-standalone"
	@echo "  smoke / smoke-admin / smoke-admin-web / smoke-admin-standalone"
	@echo ""
	@echo "── BUILD / DATA PLANE ───────────────────────────────────────"
	@echo "  build / rebuild / build-admin / build-admin-web"
	@echo "  psql / redis-cli / restart-admin / restart-admin-web / test / clean"

# ─────────────────────────────────────────────────────────────────────
# Production: up
# ─────────────────────────────────────────────────────────────────────
up-p1:
	docker compose $(COMPOSE_P1) up -d

up-p1-p2:
	docker compose $(COMPOSE_P1_P2) up -d

up-p1-admin:
	docker compose $(COMPOSE_P1_ADMIN) up -d

up-p1-admin-web:
	docker compose $(COMPOSE_P1_ADMIN_WEB) up -d

# Aliases (Admin-Web requires Admin → admin is included automatically).
up-admin:      up-p1-admin
up-admin-web:  up-p1-admin-web

# Only-mode: touch only the specified service(s) in the production stack.
up-admin-only:
	docker compose $(COMPOSE_P1_ADMIN) up -d --no-deps admin-service

up-admin-web-only:
	docker compose $(COMPOSE_P1_ADMIN_WEB) up -d --no-deps admin-service admin-web

# ─────────────────────────────────────────────────────────────────────
# Local: up
# ─────────────────────────────────────────────────────────────────────
up-p1-local:
	docker compose $(COMPOSE_P1_LOCAL) up -d

up-p1-p2-local:
	docker compose $(COMPOSE_P1_P2_LOCAL) up -d

up-p1-admin-local:
	docker compose $(COMPOSE_P1_ADMIN_LOCAL) up -d

up-p1-admin-web-local:
	docker compose $(COMPOSE_P1_ADMIN_WEB_LOCAL) up -d

up-admin-local:      up-p1-admin-local
up-admin-web-local:  up-p1-admin-web-local

up-admin-only-local:
	docker compose $(COMPOSE_P1_ADMIN_LOCAL) up -d --no-deps admin-service

up-admin-web-only-local:
	docker compose $(COMPOSE_P1_ADMIN_WEB_LOCAL) up -d --no-deps admin-service admin-web

# ─────────────────────────────────────────────────────────────────────
# Admin standalone
# ─────────────────────────────────────────────────────────────────────
up-admin-standalone:
	docker compose $(COMPOSE_STANDALONE) up -d admin-service

up-admin-standalone-db:
	docker compose $(COMPOSE_STANDALONE) --profile with-db up -d

up-admin-standalone-web:
	docker compose $(COMPOSE_STANDALONE) $(COMPOSE_WEB_OV) up -d

# ─────────────────────────────────────────────────────────────────────
# Down (mirrors up-* exactly)
# ─────────────────────────────────────────────────────────────────────
down:
	docker compose $(COMPOSE_P1) down

down-local:
	docker compose $(COMPOSE_P1_LOCAL) down -v

down-p1-admin:
	docker compose $(COMPOSE_P1_ADMIN) down
down-admin: down-p1-admin

down-p1-admin-web:
	docker compose $(COMPOSE_P1_ADMIN_WEB) down
down-admin-web: down-p1-admin-web

down-p1-admin-local:
	docker compose $(COMPOSE_P1_ADMIN_LOCAL) down -v
down-admin-local: down-p1-admin-local

down-p1-admin-web-local:
	docker compose $(COMPOSE_P1_ADMIN_WEB_LOCAL) down -v
down-admin-web-local: down-p1-admin-web-local

# Only mode: stop and remove just the targeted service(s).
down-admin-only:
	docker compose $(COMPOSE_P1_ADMIN) stop admin-service
	docker compose $(COMPOSE_P1_ADMIN) rm -f admin-service

down-admin-web-only:
	docker compose $(COMPOSE_P1_ADMIN_WEB) stop admin-web admin-service
	docker compose $(COMPOSE_P1_ADMIN_WEB) rm -f admin-web admin-service

down-admin-only-local:
	docker compose $(COMPOSE_P1_ADMIN_LOCAL) stop admin-service
	docker compose $(COMPOSE_P1_ADMIN_LOCAL) rm -f admin-service

down-admin-web-only-local:
	docker compose $(COMPOSE_P1_ADMIN_WEB_LOCAL) stop admin-web admin-service
	docker compose $(COMPOSE_P1_ADMIN_WEB_LOCAL) rm -f admin-web admin-service

down-admin-standalone:
	docker compose $(COMPOSE_STANDALONE) --profile with-db down -v

# ─────────────────────────────────────────────────────────────────────
# Restart
# ─────────────────────────────────────────────────────────────────────
restart-admin:
	docker compose $(COMPOSE_P1_ADMIN) restart admin-service

restart-admin-web:
	docker compose $(COMPOSE_P1_ADMIN_WEB) restart admin-web

# ─────────────────────────────────────────────────────────────────────
# Diagnostics
# ─────────────────────────────────────────────────────────────────────
logs:
	docker compose $(COMPOSE_BASE) logs -f --tail=200

admin-logs:
	docker compose $(COMPOSE_P1_ADMIN) logs -f --tail=200 admin-service

admin-web-logs:
	docker compose $(COMPOSE_P1_ADMIN_WEB) logs -f --tail=200 admin-web

admin-standalone-logs:
	docker compose $(COMPOSE_STANDALONE) logs -f --tail=200 admin-service

ps:
	docker compose $(COMPOSE_BASE) ps

ps-admin:
	docker compose $(COMPOSE_P1_ADMIN) ps

ps-admin-web:
	docker compose $(COMPOSE_P1_ADMIN_WEB) ps

ps-local:
	docker compose $(COMPOSE_P1_LOCAL) ps

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
	docker compose $(COMPOSE_P1_ADMIN) build admin-service

build-admin-web:
	docker compose $(COMPOSE_P1_ADMIN_WEB) build admin-web

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
	@echo "  Admin-Web      : cd ../Guardrails-Service-Admin-Web      && npm run build"
	@echo "  Detection-Eng. : cd ../../DA(Python,R,...)/Guardrails-Service-Detection-Engine && pytest"

clean:
	docker compose $(COMPOSE_BASE) down -v --remove-orphans
	-docker compose $(COMPOSE_STANDALONE) --profile with-db down -v --remove-orphans
