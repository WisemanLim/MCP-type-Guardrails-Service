# Makefile — 코드 리뷰 / Code Review

> 리뷰 레벨 / Review Level: 2
> [← INDEX.md](INDEX.md)

## 파일 요약 / File Summary

- 역할 / Role: `phases × suffixes` 매트릭스로 `up-/down-` 타깃을 자동 생성하고, `smoke`/`logs`/`build`/`psql` 등 운영 보조 타깃을 제공.
- 진입점에서의 거리 / Distance from entrypoint: **0** (자체가 모든 운영 진입점).
- 라인 수 / LOC: 273.
- 주요 export / Exports (PHONY): `up-p1`, `up-p1-p2`, `up-p1-admin[-web][-local]`, `up-p1-p2-admin[-web][-local]`, `up-admin-standalone[-db|-web]`, `up-admin-{,web-}only[-local]`, `restart-admin{,-web}`, `down-*` 거울상 + `logs`, `admin-logs`, `ps*`, `build`, `rebuild`, `smoke*`, `psql`, `redis-cli`, `test`, `clean`, `help`, `list-targets`.
- 의존 모듈 / Depends on (internal): 8개 docker-compose 파일, `scripts/smoke.sh`.
- 사용된 외부 패키지 / External: `make` (GNU 권장), `docker compose` v2 CLI, `bash` (`SHELL := /bin/bash`), `curl`, `jq` (optional via shell `||`).
- 부수효과 / Side effects: 컨테이너/볼륨/네트워크 생성·제거, 호스트 포트 바인딩, 셸 명령 stdout.
- 동시성 모델 / Concurrency: 없음 (직렬 셸 호출).
- 테스트 커버리지 흔적 / Test coverage signal: 없음. 변경 검증은 `make -n <target>` dry-run에 의존.

## 라인 단위 분석 / Line-by-line Analysis

### Block 1 — Compose 변수 정의 (라인 1–36)

```Makefile path=Makefile lines=1-36
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
```

**분석 / Analysis (Level 2)**

- `SHELL := /bin/bash` — recipe 셸을 `bash`로 고정. macOS 기본 `sh` 호환 이슈 회피. *왜:* `set -o pipefail` 같은 bash 한정 기능을 안전하게 사용하려는 의도.
- `COMPOSE_BASE := -f docker-compose.yml` — 모든 compose 호출에 항상 붙는 베이스 플래그. 단순 문자열 변수이지만 `:=` (즉시 평가)를 써서 *나중에 재정의되어도 호출 시점이 아닌 정의 시점*에 값이 박힌다. recursive `=` 와의 차이 — 매크로/함수에서 변수 참조가 재귀적으로 바뀌는 사고 방지.
- `PHASE_FLAGS_p1` / `PHASE_FLAGS_p1-p2` — 변수 이름에 phase 토큰을 *문자열*로 박아놓고, 호출부 `$(PHASE_FLAGS_$(1))`에서 `$(1)`을 갈아끼움 (dispatch by name). `p1-p2` 의 하이픈은 Make 변수 이름에 허용되지만, 셸 변수 명명규약과는 다르므로 *혼동 주의*.
- `OV_*` — overlay 파일 단편. 합성 순서가 중요해 *변수 단위로 추출*해놓고 SUFFIX 정의에서 결합.
- 라인 18–19 주석 (`CRITICAL: local.yml after admin.yml…`) — Docker Compose는 *나중에 오는 `-f`*가 이전을 override. `local.yml`의 `depends_on: !reset []`이 admin.yml의 `depends_on: { postgres: … }` 를 무효화해 SQLite 단독 모드 부팅이 성립함. **이 주석을 지우거나 위치를 바꾸면 침묵 사고**.
- `SUFFIX_FLAGS_` (suffix 미지정) — *빈 값*. `$(SUFFIX_FLAGS_)`가 empty 로 평가되어 매크로가 안전하게 폴백.
- `CF = ...` — recursive `=` (lazy). `$(call CF,p1,admin)` 호출 시점에 `$(1)`/`$(2)` 가 인자값으로 치환.

**짚어볼 점 / Watch-outs**

- `SUFFIX_FLAGS_<key>` 의 변수 이름은 *문자열 매칭*에 의존. 누군가 `admin_local` 처럼 언더스코어로 바꾸면 `SUFFIX_FLAGS_admin_local` 변수는 정의되지 않아 무성공으로 *빈 overlay*가 되어 잘못된 stack이 뜬다. 명시적 *guard*가 없다.
- `PHASES` 와 `PHASE_FLAGS_*` 가 **두 군데**에서 동기화되어야 한다 (phase 추가 시 ① `PHASES`에 토큰 추가, ② `PHASE_FLAGS_<token>` 변수 정의). 깜빡할 경우 `eval` 단계에서 빈 변수 → `docker compose -f docker-compose.privacy.yml` (혹은 비어버림) 으로 부팅됨.
- 흔한 실수: Make 변수 이름의 `-`는 식별자에서 허용되지만, 일부 IDE 신택스 하이라이팅이 깨질 수 있음.

### Block 2 — 매크로 `MAKE_TARGETS` 정의·전개 (라인 38–61)

```Makefile path=Makefile lines=38-61
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
```

**분석 / Analysis (Level 2)**

- `define ... endef` 가 매크로 *템플릿*을 정의. 라인 시작 탭이 보존되어 recipe로 인식됨.
- `$(if $(2),-$(2))` — suffix 인자가 비어있으면 *아예 추가하지 않고*, 있으면 `-suffix` 를 붙임. → `up-p1` (suffix 없음) 과 `up-p1-admin` (있음) 양쪽이 자연스러운 이름으로 생성.
- `$$(call CF,$(1),$(2))` — *이중 달러* 가 중요. `eval`이 매크로를 전개할 때 `$$` 가 `$` 한 개로 축소되어, recipe 실행 시점에 `$(call …)`로 해석된다. *왜:* `eval`은 변수 치환을 한 번 더 거치기 때문에 *런타임 평가*를 원하면 escape 필요.
- `down` 의 `-v` 처리: `$(if $(findstring local,$(2)),-v,)` — suffix 문자열에 `local`이 포함되면 `-v`(볼륨 삭제)를 더한다. *왜:* SQLite 모드에서는 `gr-sqlite`/`audit-sqlite` 볼륨이 매번 깨끗하게 폐기되도록.
- `foreach + eval + call` 콤보는 GNU Make의 *코드 생성* 관용구. 결과적으로 phase 2개 × (suffix 5개 + 빈) = 12개의 `up-/down-` 타깃이 만들어진다.

**짚어볼 점 / Watch-outs**

- `$$(call CF,…)` 의 이중 달러를 단일 달러로 바꾸면 *매크로 정의 시점*에 한 번만 치환되어 모든 타깃이 동일한 compose 인자로 깨져 버린다. 매우 자주 나오는 실수.
- `findstring local,...` 는 substring 매칭. 만약 향후 suffix 이름에 `local`이 부분 문자열로 들어가는 새 토큰(e.g. `nonlocal`)이 추가되면 잘못된 `-v` 부착 위험.
- 자동 생성된 타깃은 `make list-targets` (라인 199) 로 열람 가능 — 새 PHASE 추가 시 검증 첫 단계로 권장.

### Block 3 — Alias 타깃 (라인 63–81)

```Makefile path=Makefile lines=63-81
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
```

**분석 / Analysis (Level 2)**

- 의존성만 가지고 recipe가 없는 타깃 = *alias*. Make는 alias의 prerequisite를 빌드한 뒤 alias 자체는 `Nothing to be done`을 출력.
- *왜:* Phase 1이 사실상 *default*이므로 `up-admin` 같은 짧은 이름을 일급 시민으로 노출. 사용자가 `make help` 를 보지 않아도 직관적 명령으로 시작 가능.

**짚어볼 점 / Watch-outs**

- alias 추가 시 Phase 2 (`p1-p2`) 에는 *동등한 alias가 없음*. 의도된 비대칭. 향후 P2 가 default가 될 때 정리 필요.

### Block 4 — Only-mode 타깃 (라인 83–124)

```Makefile path=Makefile lines=83-124
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
```

**분석 / Analysis (Level 2)**

- `up -d --no-deps <svc>` 패턴 — 이미 *core stack*이 실행 중일 때 admin 만 추가/교체하는 용도. compose는 평소 같으면 `depends_on` 의존 서비스를 함께 시작하지만 `--no-deps` 가 그 동작을 끊는다.
- `down-admin-*-only` 가 `down` 이 아닌 `stop` + `rm -f` 조합인 이유: `docker compose down`은 *프로젝트 전체*를 내림 → 코어 stack까지 종료된다. 대신 단일 서비스를 *정확히* 끄려면 `stop` 후 `rm -f`로 컨테이너 자체를 제거. 네트워크/볼륨은 보존.

**짚어볼 점 / Watch-outs**

- `docker compose stop` 후 `rm -f` 는 *2-step* 이지만 중간에 실패해도 그대로 진행. 운영자가 잘못된 `--profile` 등으로 `stop` 실패 시 컨테이너가 남아있을 수 있음.
- `restart-admin-web` 은 `restart admin-web` 만 호출 — admin-service 가 동시에 재시작 안 됨. 의도일 수 있으나 *API 호환 깨짐*이 있는 페어 배포 때는 운영자가 두 줄을 직접 호출해야 함.

### Block 5 — Standalone 타깃 (라인 126–141)

```Makefile path=Makefile lines=126-141
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
```

**분석 / Analysis (Level 2)**

- `COMPOSE_STANDALONE` 은 `docker-compose.admin-standalone.yml` 단독 호출 — base compose 를 포함하지 않음. 이름 그대로 *독립 stack*.
- `--profile with-db` 가 활성화될 때만 `admin-postgres` 서비스가 시동 (`docker-compose.admin-standalone.yml:26` 의 `profiles: ["with-db"]`).
- `up-admin-standalone-web` 은 `OV_WEB`(`admin-web.yml`)를 overlay 로 결합 — 단일 호스트에서 admin + admin-web 동시 기동.
- `down-admin-standalone` 은 `--profile with-db` 와 `-v` 를 함께 사용 → DB 볼륨까지 완전 폐기. 명시적으로 *데이터 삭제* 동작이므로 운영 사고 위험.

**짚어볼 점 / Watch-outs**

- `down-admin-standalone` 에 `-v` 가 무조건 포함 — `up-admin-standalone` (db 없음)으로 시작했더라도 `down` 시 `--profile with-db` 를 명시해 *없는 프로파일* 도 한꺼번에 정리하려는 의도. 그러나 *외부 DB* 모드로 운영한 사용자가 실수로 호출하면 `admin-data` 볼륨까지 날아간다. 명시적 confirm 없음.

### Block 6 — Help / list-targets / 진단 (라인 143–230)

```Makefile path=Makefile lines=143-230
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
	...
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
```

**분석 / Analysis (Level 2)**

- `help` 는 모든 `@echo` 라인을 stdout에 출력하고 끝. *왜:* 처음 들어온 사용자가 `make help` 만으로 자주 쓰는 명령을 훑어볼 수 있게.
- `list-targets` 는 자동 생성된 타깃 목록을 동적으로 재구성. `foreach` 가 매 호출마다 `PHASES × SUFFIXES` 를 다시 평가하므로 새 PHASE/SUFFIX 추가 후 추가 작업 없이 곧장 목록에 반영됨.
- `logs` 변종들이 *compose 파일 조합을 달리한다* — `logs` 는 base 만, `admin-logs` 는 `base + privacy + admin`, `admin-standalone-logs` 는 독립 stack. *왜:* compose 가 “프로젝트” 식별을 디렉토리·파일 조합으로 하기 때문에, 잘못된 -f 조합으로 호출하면 “No such service” 또는 *다른 프로젝트의 컨테이너*에 붙어버린다.

**짚어볼 점 / Watch-outs**

- `ps-local` 은 `$(call CF,p1,local)` — `p1 + local` (no admin) 조합. 만약 사용자가 `up-p1-admin-local`로 띄웠다면 `ps-local` 호출 시 admin 서비스가 *목록에 나타나지 않거나* 혹은 compose가 합성 안 된 yml 로 인해 일관성 오류 메시지. 명령 매트릭스가 `up`/`ps` 양쪽 모두 정확히 같은 -f 조합으로 호출되어야 함을 인지.

### Block 7 — Build / smoke / 인프라 접근 / test / clean (라인 232–273)

```Makefile path=Makefile lines=232-273
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

test:
	@echo "Run per-service tests under their own directories."
	...

clean:
	docker compose $(COMPOSE_BASE) down -v --remove-orphans
	-docker compose $(COMPOSE_STANDALONE) --profile with-db down -v --remove-orphans
```

**분석 / Analysis (Level 2)**

- `build` 는 base 만 빌드 — `admin-service`/`admin-web` 은 base 에 정의되지 않으므로 별도 `build-admin{,-web}` 가 존재. `$(call CF,p1,admin)` 등으로 *해당 서비스가 정의된 yml을 포함*하는 식.
- `rebuild` = `--no-cache` 빌드. 캐시 무효화 강제. 의존 패키지 lock 변경 후 사용.
- `smoke-admin` / `smoke-admin-web` — Makefile 변수 확장(`$()`)이 아니라 *셸 변수 확장* (`$${VAR:-default}`)을 쓴 점이 핵심. `$$` 한 쌍은 *make 자체의 escape*로 단일 `$`가 되어 쉘에서 평가되고, `:-default` 는 bash 파라미터 확장 (변수 미설정/공백 시 default 사용). *왜:* `make` 호출 시점이 아닌 *recipe 실행 시점의 환경*을 읽어야 호스트 `.env`/세션 변수가 반영된다.
- `psql` / `redis-cli` — `docker compose exec` 로 컨테이너 내부 진단 도구로 접속. 운영자 편의용.
- `clean` 첫 줄은 base stack 폐기 (볼륨 포함). 둘째 줄은 standalone stack까지 한 번에 폐기. `-` 접두는 *“실패해도 멈추지 말라”*는 GNU Make의 ignore-error 지시. standalone가 처음부터 안 떠있어도 clean이 종료되도록.
- `test` 는 *진짜 테스트가 아님* — 안내 메시지만 출력. 각 서비스 폴더의 `npm test`/`pytest`를 사용자가 직접 호출하도록 유도.

**짚어볼 점 / Watch-outs**

- `smoke-admin` 의 `jq . 2>/dev/null || cat` 패턴 — `jq` 미설치 시 fallback. 그러나 *jq 없음 + 응답 JSON 큰 경우* 사람이 보기 어려운 raw 출력. 운영 워크스테이션에 `jq` 설치 권장.
- `clean` 이 standalone까지 항상 정리 — 운영자가 *standalone 만 띄워 사용 중인* 호스트에서 `make clean`을 누르면 의도하지 않은 stack 까지 함께 날아간다. 이름이 추상적이라 사고 위험.

## 파일 수준 평가 / File-Level Verdict

- 강점 / Strengths:
  1. `phases × suffixes` 매트릭스 디자인이 *확장 비용 = 변수 한 줄*. 운영 명령의 확장성이 매우 좋음.
  2. 합성 순서 의존성을 *주석 + 변수 분리*로 명시 (라인 18–19). 암묵 지식의 명시화.
  3. `help` / `list-targets` 가 자기 문서화 — 신규 운영자가 들어와도 `make help` 한 줄로 시작 가능.
- 위험 / Risks:
  1. `clean` 이 standalone까지 *무조건* 폐기 — 의도 불명료, 사고 위험.
  2. `findstring local,...` 으로 `-v` 분기 — substring 매칭의 위양성 위험(향후 suffix 명칭 추가 시).
  3. `test` 가 실제 테스트를 돌리지 않음 — CI 통합 시 별도 orchestrator 필요.
- 개선 권고 / Recommendations (impact 순):
  1. `make _confirm` 같은 가드(`@read -p "REALLY clean standalone too? [y/N] "`)를 `clean` 앞단에 두기. 또는 `clean-all` / `clean-base` / `clean-standalone` 으로 분리.
  2. `findstring local,...` 를 정확 매칭(`filter local%`)으로 바꿔 향후 suffix 충돌 차단.
  3. `test` 타깃이 각 서비스 디렉토리로 들어가 `npm test` / `pytest`를 실제로 호출하도록 확장하거나, 또는 *문서화 전용* 표시를 명확히 (`help-test`).
- 재읽기 권고 레벨 / Suggested re-read level: **3** — Level 3 로 다시 읽으면 매크로 generator 패턴과 dependency-flag 합성 의도가 “시스템 설계 결정”으로 묶여 보임.
