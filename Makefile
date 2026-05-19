SHELL := /bin/bash

COMPOSE_BASE    := -f docker-compose.yml
COMPOSE_PRIVACY := $(COMPOSE_BASE) -f docker-compose.privacy.yml
COMPOSE_FOOD    := $(COMPOSE_PRIVACY) -f docker-compose.food.yml
COMPOSE_LOCAL   := $(COMPOSE_PRIVACY) -f docker-compose.local.yml

.PHONY: help up-p1 up-p1-p2 up-local down down-local logs ps build rebuild psql redis-cli smoke test clean

help:
	@echo "Targets:"
	@echo "  up-p1         Start core + Phase 1 (privacy) with Postgres + Redis."
	@echo "  up-p1-p2      Start core + Phase 1 + Phase 2 (food) [stub]."
	@echo "  up-local      Start Phase 1 with SQLite (no Postgres / Redis)."
	@echo "  down          Stop and remove containers (Postgres stack)."
	@echo "  down-local    Stop and remove containers (SQLite stack)."
	@echo "  logs          Tail all logs."
	@echo "  ps            List running services."
	@echo "  build         Build all images."
	@echo "  rebuild       Build images with --no-cache."
	@echo "  psql          psql shell into the database."
	@echo "  redis-cli     Redis CLI into the cache."
	@echo "  smoke         Run smoke test against the running MCP HTTP transport."
	@echo "  test          Run per-service test suites (host-side)."

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

logs:
	docker compose $(COMPOSE_BASE) logs -f --tail=200

ps:
	docker compose $(COMPOSE_BASE) ps

build:
	docker compose $(COMPOSE_BASE) build

rebuild:
	docker compose $(COMPOSE_BASE) build --no-cache

psql:
	docker compose $(COMPOSE_BASE) exec postgres psql -U $${POSTGRES_USER:-guardrails} -d $${POSTGRES_DB:-guardrails}

redis-cli:
	docker compose $(COMPOSE_BASE) exec redis redis-cli

smoke:
	@bash ./scripts/smoke.sh

test:
	@echo "Run per-service tests under their own directories."
	@echo "  Server         : cd ../Guardrails-Service-Server         && npm test"
	@echo "  Policy-Engine  : cd ../Guardrails-Service-Policy-Engine  && npm test"
	@echo "  Audit-Service  : cd ../Guardrails-Service-Audit-Service  && npm test"
	@echo "  Detection-Eng. : cd ../../DA(Python,R,...)/Guardrails-Service-Detection-Engine && pytest"

clean:
	docker compose $(COMPOSE_BASE) down -v --remove-orphans
