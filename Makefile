SHELL := /bin/bash

# Compose stack definitions.
COMPOSE_BASE       := -f docker-compose.yml
COMPOSE_PRIVACY    := $(COMPOSE_BASE) -f docker-compose.privacy.yml
COMPOSE_FOOD       := $(COMPOSE_PRIVACY) -f docker-compose.food.yml
COMPOSE_LOCAL      := $(COMPOSE_PRIVACY) -f docker-compose.local.yml
# Admin overlay sits on top of the main stack (shares postgres/redis).
COMPOSE_ADMIN      := $(COMPOSE_PRIVACY) -f docker-compose.admin.yml
# Admin standalone is a self-contained compose file (no base merge).
COMPOSE_STANDALONE := -f docker-compose.admin-standalone.yml

.PHONY: help \
        up-p1 up-p1-p2 up-local \
        up-admin up-p1-admin up-admin-only \
        up-admin-standalone up-admin-standalone-db \
        restart-admin \
        down down-local down-admin down-admin-only down-admin-standalone \
        logs admin-logs admin-standalone-logs \
        ps ps-admin ps-standalone \
        build rebuild build-admin \
        psql redis-cli \
        smoke smoke-admin smoke-admin-standalone \
        test clean

help:
	@echo "── Main stack ────────────────────────────────────────────────"
	@echo "  up-p1                    Postgres + Redis + Phase 1 (privacy)."
	@echo "  up-p1-p2                 Phase 1 + Phase 2 (food) [stub]."
	@echo "  up-local                 SQLite-only mode (no Postgres / Redis)."
	@echo "  down                     Stop and remove main-stack containers."
	@echo "  down-local               Stop and remove SQLite-mode containers."
	@echo "── Admin co-located (overlay on main stack) ──────────────────"
	@echo "  up-admin                 main stack + Admin (alias up-p1-admin)."
	@echo "  up-p1-admin              Same as up-admin."
	@echo "  up-admin-only            Only (re)start admin-service in the running"
	@echo "                           main stack. Does NOT touch other services."
	@echo "  restart-admin            Restart only admin-service."
	@echo "  down-admin               Stop ALL containers including admin."
	@echo "  down-admin-only          Stop ONLY the admin-service container."
	@echo "── Admin standalone (separate host / network) ────────────────"
	@echo "  up-admin-standalone      Standalone Admin, external DB via env."
	@echo "  up-admin-standalone-db   Standalone Admin + bundled Postgres (port 5433)."
	@echo "  down-admin-standalone    Stop standalone Admin stack."
	@echo "── Diagnostics / smoke ──────────────────────────────────────"
	@echo "  logs / admin-logs / admin-standalone-logs"
	@echo "  ps  / ps-admin / ps-standalone"
	@echo "  smoke                    MCP HTTP smoke."
	@echo "  smoke-admin              /admin/health on the co-located admin."
	@echo "  smoke-admin-standalone   /admin/health on the standalone admin."
	@echo "── Build / data plane ───────────────────────────────────────"
	@echo "  build / rebuild / build-admin / psql / redis-cli / test / clean"

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

# Start ONLY admin-service in the existing main stack (no side-effects on
# postgres/redis/mcp/policy/detection/audit). Useful for hot-replacing admin
# after a build without bouncing the data plane.
up-admin-only:
	docker compose $(COMPOSE_ADMIN) up -d --no-deps admin-service

restart-admin:
	docker compose $(COMPOSE_ADMIN) restart admin-service

down-admin:
	docker compose $(COMPOSE_ADMIN) down

# Tear down ONLY admin-service. Leaves the rest of the stack running.
down-admin-only:
	docker compose $(COMPOSE_ADMIN) stop admin-service
	docker compose $(COMPOSE_ADMIN) rm -f admin-service

# ─────────────────────────────────────────────────────────────────────
# Admin standalone
# ─────────────────────────────────────────────────────────────────────
# Standalone deployment: independent compose file, no link to the main
# stack. Useful when Admin lives on its own host or VPN, talking to an
# external Postgres + external Policy Engine.
up-admin-standalone:
	docker compose $(COMPOSE_STANDALONE) up -d admin-service

# Same as above plus a bundled Postgres (binds to host port 5433 by default
# to avoid clashing with a co-located main-stack Postgres on 5432).
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

# ─────────────────────────────────────────────────────────────────────
# Smoke
# ─────────────────────────────────────────────────────────────────────
smoke:
	@bash ./scripts/smoke.sh

smoke-admin:
	@curl -fsS http://localhost:$${ADMIN_EXPOSED_PORT:-8084}/admin/health | (jq . 2>/dev/null || cat)

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
	@echo "  Detection-Eng. : cd ../../DA(Python,R,...)/Guardrails-Service-Detection-Engine && pytest"

clean:
	docker compose $(COMPOSE_BASE) down -v --remove-orphans
	-docker compose $(COMPOSE_STANDALONE) --profile with-db down -v --remove-orphans
