SHELL := /bin/bash

# ─────────────────────────────────────────────────────────────────────
# Compose building blocks
# ─────────────────────────────────────────────────────────────────────
COMPOSE_BASE := -f docker-compose.yml

# Phase chains (extend here when adding p3, p4, ... — append to PHASES too).
PHASE_FLAGS_p1       := $(COMPOSE_BASE) -f docker-compose.privacy.yml
PHASE_FLAGS_p1-p2    := $(PHASE_FLAGS_p1) -f docker-compose.food.yml

# Overlay fragments
OV_ADMIN       := -f docker-compose.admin.yml
OV_WEB         := -f docker-compose.admin-web.yml
OV_LOCAL       := -f docker-compose.local.yml
OV_ADMIN_LOCAL := -f docker-compose.admin-local.yml

# Suffix → ordered overlays. CRITICAL: local.yml after admin.yml so its
# `depends_on: !reset []` overrides admin.yml's postgres dependency.
SUFFIX_FLAGS_                   :=
SUFFIX_FLAGS_admin              := $(OV_ADMIN)
SUFFIX_FLAGS_admin-web          := $(OV_ADMIN) $(OV_WEB)
SUFFIX_FLAGS_local              := $(OV_LOCAL)
SUFFIX_FLAGS_admin-local        := $(OV_ADMIN) $(OV_LOCAL) $(OV_ADMIN_LOCAL)
SUFFIX_FLAGS_admin-web-local    := $(OV_ADMIN) $(OV_WEB) $(OV_LOCAL) $(OV_ADMIN_LOCAL)

# Standalone (independent)
COMPOSE_STANDALONE := -f docker-compose.admin-standalone.yml

# Helper: compose flags for (phase, suffix). Suffix may be empty.
# Usage: $(call CF,p1,admin-web-local)
CF = $(PHASE_FLAGS_$(1)) $(SUFFIX_FLAGS_$(2))

# Phases × suffixes matrix.
PHASES   := p1 p1-p2
SUFFIXES := admin admin-web local admin-local admin-web-local

# ─────────────────────────────────────────────────────────────────────
# Macro: generate up-<phase>[-<suffix>] and down-<phase>[-<suffix>]
# ─────────────────────────────────────────────────────────────────────
#   $(1) = phase    (e.g. p1, p1-p2)
#   $(2) = suffix   (empty | admin | admin-web | local | admin-local | admin-web-local)
#
# down also passes -v whenever the suffix includes `local` so SQLite
# volumes are dropped on teardown.
define MAKE_TARGETS
.PHONY: up-$(1)$(if $(2),-$(2)) down-$(1)$(if $(2),-$(2))

up-$(1)$(if $(2),-$(2)):
	@echo "▶ up   phase=$(1) suffix=$(if $(2),$(2),«none»)"
	docker compose $$(call CF,$(1),$(2)) up -d

down-$(1)$(if $(2),-$(2)):
	@echo "▶ down phase=$(1) suffix=$(if $(2),$(2),«none»)"
	docker compose $$(call CF,$(1),$(2)) down $(if $(findstring local,$(2)),-v,)
endef

# Base targets (no suffix)
$(foreach P,$(PHASES),$(eval $(call MAKE_TARGETS,$(P),)))
# Suffix combinations
$(foreach P,$(PHASES),$(foreach S,$(SUFFIXES),$(eval $(call MAKE_TARGETS,$(P),$(S)))))

# ─────────────────────────────────────────────────────────────────────
# Aliases — `up-admin*` and `up-admin-web*` shortcut to the P1 form.
# ─────────────────────────────────────────────────────────────────────
.PHONY: up-admin up-admin-web up-admin-local up-admin-web-local \
        down-admin down-admin-web down-admin-local down-admin-web-local \
        down down-local

up-admin:          up-p1-admin
up-admin-web:      up-p1-admin-web
up-admin-local:    up-p1-admin-local
up-admin-web-local: up-p1-admin-web-local

down-admin:          down-p1-admin
down-admin-web:      down-p1-admin-web
down-admin-local:    down-p1-admin-local
down-admin-web-local: down-p1-admin-web-local

down:        down-p1
down-local:  down-p1-local

# ─────────────────────────────────────────────────────────────────────
# Only-mode — touch only admin / admin-web in a running stack.
# ─────────────────────────────────────────────────────────────────────
.PHONY: up-admin-only down-admin-only \
        up-admin-only-local down-admin-only-local \
        up-admin-web-only down-admin-web-only \
        up-admin-web-only-local down-admin-web-only-local \
        restart-admin restart-admin-web

up-admin-only:
	docker compose $(call CF,p1,admin) up -d --no-deps admin-service

up-admin-only-local:
	docker compose $(call CF,p1,admin-local) up -d --no-deps admin-service

up-admin-web-only:
	docker compose $(call CF,p1,admin-web) up -d --no-deps admin-service admin-web

up-admin-web-only-local:
	docker compose $(call CF,p1,admin-web-local) up -d --no-deps admin-service admin-web

down-admin-only:
	docker compose $(call CF,p1,admin) stop admin-service
	docker compose $(call CF,p1,admin) rm -f admin-service

down-admin-only-local:
	docker compose $(call CF,p1,admin-local) stop admin-service
	docker compose $(call CF,p1,admin-local) rm -f admin-service

down-admin-web-only:
	docker compose $(call CF,p1,admin-web) stop admin-web admin-service
	docker compose $(call CF,p1,admin-web) rm -f admin-web admin-service

down-admin-web-only-local:
	docker compose $(call CF,p1,admin-web-local) stop admin-web admin-service
	docker compose $(call CF,p1,admin-web-local) rm -f admin-web admin-service

restart-admin:
	docker compose $(call CF,p1,admin) restart admin-service

restart-admin-web:
	docker compose $(call CF,p1,admin-web) restart admin-web

# ─────────────────────────────────────────────────────────────────────
# Standalone
# ─────────────────────────────────────────────────────────────────────
.PHONY: up-admin-standalone up-admin-standalone-db up-admin-standalone-web down-admin-standalone

up-admin-standalone:
	docker compose $(COMPOSE_STANDALONE) up -d admin-service

up-admin-standalone-db:
	docker compose $(COMPOSE_STANDALONE) --profile with-db up -d

up-admin-standalone-web:
	docker compose $(COMPOSE_STANDALONE) $(OV_WEB) up -d

down-admin-standalone:
	docker compose $(COMPOSE_STANDALONE) --profile with-db down -v

# ─────────────────────────────────────────────────────────────────────
# Diagnostics / smoke / build / misc
# ─────────────────────────────────────────────────────────────────────
.PHONY: help list-targets \
        logs admin-logs admin-web-logs admin-standalone-logs \
        ps ps-admin ps-admin-web ps-local ps-standalone \
        build rebuild build-admin build-admin-web \
        smoke smoke-admin smoke-admin-web smoke-admin-standalone \
        psql redis-cli test clean

help:
	@echo "── PRODUCTION (Postgres + Redis) ────────────────────────────"
	@echo "  up-p1                       Phase 1 (privacy)"
	@echo "  up-p1-admin (= up-admin)    + Admin API"
	@echo "  up-p1-admin-web (= up-admin-web)"
	@echo "                              + Admin API + Admin Web (3001)"
	@echo "  up-p1-p2                    Phase 1 + Phase 2 (food)"
	@echo "  up-p1-p2-admin              ... + Admin API"
	@echo "  up-p1-p2-admin-web          ... + Admin API + Web"
	@echo ""
	@echo "── LOCAL (SQLite, no Postgres/Redis) ────────────────────────"
	@echo "  up-p1-local"
	@echo "  up-p1-admin-local (= up-admin-local)"
	@echo "  up-p1-admin-web-local (= up-admin-web-local)"
	@echo "  up-p1-p2-local"
	@echo "  up-p1-p2-admin-local"
	@echo "  up-p1-p2-admin-web-local"
	@echo ""
	@echo "── ONLY-MODE (lifecycle only admin / admin+web) ─────────────"
	@echo "  up-admin-only / down-admin-only"
	@echo "  up-admin-only-local / down-admin-only-local"
	@echo "  up-admin-web-only / down-admin-web-only"
	@echo "  up-admin-web-only-local / down-admin-web-only-local"
	@echo "  restart-admin / restart-admin-web"
	@echo ""
	@echo "── STANDALONE (independent host) ────────────────────────────"
	@echo "  up-admin-standalone"
	@echo "  up-admin-standalone-db"
	@echo "  up-admin-standalone-web"
	@echo "  down-admin-standalone"
	@echo ""
	@echo "── DOWN — mirror of up-* targets ────────────────────────────"
	@echo "  down / down-local"
	@echo "  down-p1[-admin|-admin-web][-local]"
	@echo "  down-p1-p2[-admin|-admin-web][-local]"
	@echo ""
	@echo "── DIAGNOSTICS / SMOKE / BUILD ──────────────────────────────"
	@echo "  logs / admin-logs / admin-web-logs / admin-standalone-logs"
	@echo "  ps / ps-admin / ps-admin-web / ps-local / ps-standalone"
	@echo "  smoke / smoke-admin / smoke-admin-web / smoke-admin-standalone"
	@echo "  build / rebuild / build-admin / build-admin-web"
	@echo "  psql / redis-cli / test / clean"
	@echo ""
	@echo "── SEED (load scripts/*.json into rules, no Policy needed) ──"
	@echo "  seed          load scripts/*.json -> rules (idempotent)"
	@echo "  reseed        replace source='file' rows (admin rows kept)"
	@echo "  seed-sql      render SQL to build/seed-rules.sql (no DB write)"
	@echo "  seed-verify   print rule counts per domain"
	@echo "  reset-rules   DANGER: delete ALL source='file' rows"
	@echo ""
	@echo "Run 'make list-targets' to print every generated target."

# Auxiliary: list all generated up/down targets so users can grep.
list-targets:
	@printf '%s\n' \
	  $(foreach P,$(PHASES),up-$(P) down-$(P)) \
	  $(foreach P,$(PHASES),$(foreach S,$(SUFFIXES),up-$(P)-$(S) down-$(P)-$(S))) \
	  | sort

logs:
	docker compose $(COMPOSE_BASE) logs -f --tail=200

admin-logs:
	docker compose $(call CF,p1,admin) logs -f --tail=200 admin-service

admin-web-logs:
	docker compose $(call CF,p1,admin-web) logs -f --tail=200 admin-web

admin-standalone-logs:
	docker compose $(COMPOSE_STANDALONE) logs -f --tail=200 admin-service

ps:
	docker compose $(COMPOSE_BASE) ps

ps-admin:
	docker compose $(call CF,p1,admin) ps

ps-admin-web:
	docker compose $(call CF,p1,admin-web) ps

ps-local:
	docker compose $(call CF,p1,local) ps

ps-standalone:
	docker compose $(COMPOSE_STANDALONE) ps

build:
	docker compose $(COMPOSE_BASE) build

rebuild:
	docker compose $(COMPOSE_BASE) build --no-cache

build-admin:
	docker compose $(call CF,p1,admin) build admin-service

build-admin-web:
	docker compose $(call CF,p1,admin-web) build admin-web

smoke:
	@bash ./scripts/smoke.sh

smoke-admin:
	@curl -fsS http://localhost:$${ADMIN_EXPOSED_PORT:-8084}/admin/health | (jq . 2>/dev/null || cat)

smoke-admin-web:
	@curl -fsS -o /dev/null -w "HTTP %{http_code}\n" http://localhost:$${ADMIN_WEB_EXPOSED_PORT:-3001}/login

smoke-admin-standalone:
	@curl -fsS http://localhost:$${ADMIN_EXPOSED_PORT:-8084}/admin/health | (jq . 2>/dev/null || cat)

psql:
	docker compose $(COMPOSE_BASE) exec postgres psql -U $${POSTGRES_USER:-guardrails} -d $${POSTGRES_DB:-guardrails}

redis-cli:
	docker compose $(COMPOSE_BASE) exec redis redis-cli

# ─────────────────────────────────────────────────────────────────────
# Seed loading — load scripts/*.json bundles straight into the `rules`
# table WITHOUT a running Policy Engine. Normally Policy seeds on first
# boot (seedIfNeeded); use these when you brought up only Postgres/Redis,
# or Policy could not reach the DB and `rules` stayed empty.
#
# scripts/load-seeds.py is stdlib-only and never connects to Postgres — it
# renders idempotent SQL (source='file', ON CONFLICT (rule_id) DO NOTHING,
# same column mapping as DbService.bulkInsertRules) which we pipe into the
# running container's psql. No host psql / pg driver required.
#
# Override connection: make seed POSTGRES_USER=u POSTGRES_DB=d
# ─────────────────────────────────────────────────────────────────────
SEED_PSQL = docker compose $(COMPOSE_BASE) exec -T postgres \
            psql -v ON_ERROR_STOP=1 \
              -U $${POSTGRES_USER:-guardrails} -d $${POSTGRES_DB:-guardrails}

.PHONY: seed reseed seed-sql seed-verify reset-rules

seed:
	@echo "▶ seeding scripts/*.json into rules (idempotent)"
	python3 scripts/load-seeds.py | $(SEED_PSQL)

reseed:
	@echo "▶ reseeding (DELETE source='file' rows, then reload — admin rows kept)"
	python3 scripts/load-seeds.py --mode reseed | $(SEED_PSQL)

seed-sql:
	python3 scripts/load-seeds.py --out build/seed-rules.sql

seed-verify:
	@$(SEED_PSQL) -c "SELECT domain, count(*) AS rules, count(*) FILTER (WHERE io_type='input') AS input, count(*) FILTER (WHERE io_type='output') AS output FROM rules GROUP BY domain ORDER BY domain;"

reset-rules:
	$(SEED_PSQL) -c "DELETE FROM rules WHERE source='file';"

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
