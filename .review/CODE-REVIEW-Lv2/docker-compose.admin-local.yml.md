# docker-compose.admin-local.yml — 코드 리뷰 / Code Review

> 리뷰 레벨 / Review Level: 2
> [← INDEX.md](INDEX.md)

## 파일 요약 / File Summary

- 역할 / Role: admin × local 결합 시 admin-service 가 SQLite 모드 + postgres 의존 제거.
- 진입점에서의 거리: **2** (base + admin + local + admin-local).
- 라인 수: 27.
- 주요 export: `admin-service` env 의 `DB_DRIVER=sqlite`, `gr-sqlite` 공유 볼륨.

## 라인 단위 분석 / Line-by-Line Analysis

```yaml path=docker-compose.admin-local.yml lines=1-28
# Local-mode override for the Admin service.
#
# Applied on TOP of docker-compose.admin.yml + docker-compose.local.yml so
# admin-service uses SQLite (single-file DB) and drops its Postgres
# dependency. This overlay is split from local.yml because local.yml is
# also used by stacks that do NOT include admin-service — referencing a
# nonexistent service in local.yml would cause compose validation errors.
#
# Admin and Policy Engine SHARE the same SQLite file (/app/var/guardrails.db)
# via the `gr-sqlite` volume, so rule CRUD via Admin is immediately visible
# to Policy Engine on its next refresh / cache invalidation.
#
# Always combine with docker-compose.admin.yml. Order must be:
#   ... docker-compose.admin.yml docker-compose.local.yml docker-compose.admin-local.yml
# so the !reset on depends_on wins.

services:
  admin-service:
    environment:
      DB_DRIVER: sqlite
      SQLITE_PATH: /app/var/guardrails.db
    volumes:
      - gr-sqlite:/app/var
    depends_on: !reset []

volumes:
  gr-sqlite:
```

**분석 / Analysis (Level 2)**

- 주석이 *왜 별도 파일인지*를 명시 — `local.yml` 안에 admin 관련 override 를 넣으면 admin 미포함 stack 합성 시 “service admin-service 가 정의되지 않음” 에러를 compose 가 던지기 때문.
- `SQLITE_PATH: /app/var/guardrails.db` — *Policy Engine 과 동일 경로*. 두 컨테이너가 `gr-sqlite` 볼륨을 마운트해 *같은 파일*을 본다. SQLite 의 *동시 writer*는 WAL + busy_timeout 권고.
- `depends_on: !reset []` — admin.yml 의 `postgres: service_healthy` 의존 제거. 합성 순서가 *반드시* `admin.yml → local.yml → admin-local.yml` 이어야 reset 효력 (각 파일이 admin 의존을 *덧붙이거나 끊는다*).
- `gr-sqlite` 볼륨은 `local.yml` 에서도 선언 → compose 가 중복 항목을 dedupe.

**짚어볼 점 / Watch-outs**

- **합성 순서 의존**: 운영자가 `make` 가 아닌 *raw compose 명령*으로 호출할 때 순서를 틀리면 `depends_on` 가 reset 되지 않아 postgres healthy 를 기다리다 *영원히 대기*. 주석 line 13–15 의 명시가 critical.
- 공유 SQLite — Admin 이 *update* 한 row 가 Policy Engine 캐시에 즉시 반영되지 않을 수 있음 (각 서비스의 in-memory cache TTL 의존). 주석은 *“on its next refresh / cache invalidation”* 으로 약속하지만 *cache invalidation 채널*이 본 compose 파일만으로는 추적 불가.

## 파일 수준 평가 / File-Level Verdict

- 강점 / Strengths:
  1. *왜 별도 파일인지* 가 주석으로 명확.
  2. `!reset` 의 합성 순서 가이드 명시.
- 위험 / Risks:
  1. compose 합성 순서 의존 — `make` 외 호출 시 사고.
  2. 공유 SQLite 의 *동시 writer / cache invalidation* 가 본 파일만으로 검증 불가.
- 개선 권고 / Recommendations:
  1. `Makefile` 의 `up-*-admin-local` 타깃 외에는 *공식 호출 경로*가 없음을 README 에 강조.
  2. 형제 서비스 측에 *cache invalidation hook*(파일 watch 또는 pub/sub)을 명시.
- 재읽기 권고 레벨: **2**.
