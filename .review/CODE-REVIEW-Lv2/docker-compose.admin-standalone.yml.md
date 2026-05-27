# docker-compose.admin-standalone.yml — 코드 리뷰 / Code Review

> 리뷰 레벨 / Review Level: 2
> [← INDEX.md](INDEX.md)

## 파일 요약 / File Summary

- 역할 / Role: Admin 단독 stack — base 없이 자체적으로 admin-postgres + admin-service 구동, host.docker.internal 통한 외부 Policy Engine 호출.
- 진입점에서의 거리: **0** (base 미합성, 단독 호출).
- 라인 수: 96.
- 주요 export: `admin-postgres` (profile `with-db`), `admin-service`, `gr-admin-net` 네트워크, `admin-pg-data` / `admin-data` 볼륨.

## 라인 단위 분석 / Line-by-Line Analysis

### Block 1 — 헤더 + admin-postgres (라인 1–42)

```yaml path=docker-compose.admin-standalone.yml lines=1-43
# Admin standalone deployment — Admin runs on its own, independent of the
# main Guardrails stack. Useful for running Admin on a separate host or in
# a separate network zone.
#
# This file does NOT extend docker-compose.yml. It is self-contained.
#
# Three modes:
#
#   1. External DB + external Policy Engine (default, lightest)
#   2. Bundled Postgres (--profile with-db) on a different host port (5433)
#   3. SQLite only (DB_DRIVER=sqlite, no Postgres at all)

services:
  admin-postgres:
    image: postgres:16-alpine
    container_name: gr-admin-postgres
    profiles: ["with-db"]
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${POSTGRES_DB:-guardrails}
      POSTGRES_USER: ${POSTGRES_USER:-guardrails}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-guardrails}
    volumes:
      - admin-pg-data:/var/lib/postgresql/data
      - ./scripts/init-db.sql:/docker-entrypoint-initdb.d/01-init.sql:ro
    ports:
      - "${ADMIN_POSTGRES_PORT:-5433}:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER:-guardrails} -d ${POSTGRES_DB:-guardrails}"]
      interval: 5s
      timeout: 5s
      retries: 20
    networks: [gr-admin-net]
```

**분석 / Analysis (Level 2)**

- `profiles: ["with-db"]` — `docker compose --profile with-db up` 일 때만 시동. 운영자가 *external DB 모드*로 띄울 때는 `admin-postgres` 가 *조용히 빠진다*.
- 호스트 포트 `5433` — base의 5432와 *충돌 회피*. 같은 호스트에 두 stack을 동시 띄울 가능성을 고려한 설계.
- *동일 init-db.sql 마운트* — admin 단독에서도 같은 스키마를 사용. *왜:* admin은 base 와 동일한 `admin_users`/`admin_audit_log` 외에도 `rules` 등 일부 테이블을 읽고 쓰는 구조 (Policy Engine 부재 시 standalone 작동을 위해).

**짚어볼 점 / Watch-outs**

- `admin-pg-data` 볼륨이 base 의 `pg-data` 와 *별개*. 두 stack을 같이 띄우면 *완전히 다른 DB*가 됨. 운영자가 두 곳 모두에 룰을 등록하는 실수를 할 수 있음.
- `admin-postgres` 도 `init-db.sql` 의 모든 테이블을 만든다 — 본래 “admin 전용” 테이블만 필요하지만 base 와 같은 스키마를 *재사용*. 단일 진실 원칙 측면에서는 OK이지만 *불필요 테이블*이 만들어진다.

### Block 2 — admin-service 본체 (라인 44–87)

```yaml path=docker-compose.admin-standalone.yml lines=44-87
  admin-service:
    build:
      context: ../Guardrails-Service-Admin
      dockerfile: Dockerfile
    container_name: gr-admin-standalone
    restart: unless-stopped
    environment:
      NODE_ENV: ${NODE_ENV:-production}
      LOG_LEVEL: ${LOG_LEVEL:-info}
      PORT: 8084
      JWT_SECRET: ${ADMIN_JWT_SECRET:-change-me-in-prod}
      JWT_EXPIRES_IN: ${ADMIN_JWT_EXPIRES_IN:-12h}
      BCRYPT_ROUNDS: ${ADMIN_BCRYPT_ROUNDS:-10}
      TOTP_ISSUER: ${ADMIN_TOTP_ISSUER:-Guardrails-Admin}
      ADMIN_BOOTSTRAP_EMAIL: ${ADMIN_BOOTSTRAP_EMAIL:-}
      ADMIN_BOOTSTRAP_PASSWORD: ${ADMIN_BOOTSTRAP_PASSWORD:-}
      ADMIN_CORS_ORIGINS: ${ADMIN_CORS_ORIGINS:-}
      DB_DRIVER: ${DB_DRIVER:-postgres}
      SQLITE_PATH: ${ADMIN_SQLITE_PATH:-/app/var/admin.db}
      # When --profile with-db is active, the bundled `admin-postgres` is reachable
      # by service name. Otherwise the operator must point POSTGRES_HOST at an
      # external host.
      POSTGRES_HOST: ${POSTGRES_HOST:-admin-postgres}
      POSTGRES_PORT: ${POSTGRES_PORT:-5432}
      POSTGRES_DB: ${POSTGRES_DB:-guardrails}
      POSTGRES_USER: ${POSTGRES_USER:-guardrails}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-guardrails}
      # Default points at host.docker.internal so Admin can talk to a Policy
      # Engine running on the host (Mac/Windows). Override for prod.
      POLICY_ENGINE_URL: ${POLICY_ENGINE_URL:-http://host.docker.internal:8082}
    ports:
      - "${ADMIN_EXPOSED_PORT:-8084}:8084"
    volumes:
      - admin-data:/app/var
    healthcheck:
      test: ["CMD", "node", "-e", "require('http').get('http://127.0.0.1:8084/admin/health',r=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1))"]
      interval: 5s
      timeout: 5s
      retries: 20
      start_period: 10s
    extra_hosts:
      # Linux containers need this manually; Docker Desktop already provides it.
      - "host.docker.internal:host-gateway"
    networks: [gr-admin-net]
```

**분석 / Analysis (Level 2)**

- `POSTGRES_HOST` default = `admin-postgres` (with-db 모드 가정). external DB 모드에서는 운영자가 `.env`로 override.
- `POLICY_ENGINE_URL: ${POLICY_ENGINE_URL:-http://host.docker.internal:8082}` — *기본값이 host gateway*. Mac/Windows Docker Desktop에서는 자동 해석. Linux에서는 *명시 옵션* 이 필요 → 라인 84–86 `extra_hosts` 가 그 보강.
- `host.docker.internal:host-gateway` — Docker 20.10+ 에서 Linux 컨테이너가 *호스트 IP* 를 해석할 수 있도록 하는 magic mapping.
- `depends_on` 없음 — `with-db` 프로파일을 켜도 admin-postgres 의존이 *명시되지 않음*. 운영자가 `--profile with-db up -d` 하면 compose가 둘 다 시동하지만 *부팅 race* 가능. Admin 측의 retry/backoff 의존.

**짚어볼 점 / Watch-outs**

- `depends_on` 부재 — *Bug 후보*. `admin-postgres healthy` 조건이 빠져있어 with-db 모드에서 admin 이 *DB 미준비 상태로 부팅* 시도. 형제 서비스의 connection retry 가 처리하지 않으면 *crash loop*.
- *External DB 모드*에서 `POSTGRES_HOST` 가 `admin-postgres` (default) 상태로 둔 채 `.env` 만 외부 호스트로 안 바꿔도 *경고 없이* compose 가 시작 → DNS 실패로 컨테이너 crash. 명시적 가드 부재.
- `JWT_SECRET` default 다시 등장.

### Block 3 — 볼륨 / 네트워크 (라인 89–96)

```yaml path=docker-compose.admin-standalone.yml lines=89-96
volumes:
  admin-pg-data:
  admin-data:

networks:
  gr-admin-net:
    name: gr-admin-net
    driver: bridge
```

**분석 / Analysis (Level 2)**

- `networks.gr-admin-net.name: gr-admin-net` — *명시적 네트워크 이름 고정*. 일반적으로 compose는 `<project>_<name>` prefix를 붙이지만 본 파일은 그것을 *고정 이름*으로. 이유: standalone stack 을 *다른 compose 프로젝트*에서도 같은 네트워크에 붙이는 경우.

**짚어볼 점 / Watch-outs**

- 다른 compose 프로젝트가 같은 이름의 네트워크를 만들면 충돌. *전역 식별자*가 되어버린 점.

## 파일 수준 평가 / File-Level Verdict

- 강점 / Strengths:
  1. 단독 stack — 운영자가 *base 없이도* admin 만 띄움 가능.
  2. `extra_hosts: host-gateway` 로 Linux 호환.
  3. 세 모드(external / with-db / sqlite) 가 *주석으로 명시*.
- 위험 / Risks:
  1. `admin-service.depends_on` 없음 → with-db 모드 부팅 race.
  2. external DB 모드의 *default host 오기재* 사고 가능성.
  3. 고정 네트워크 이름 충돌.
- 개선 권고 / Recommendations (impact 순):
  1. `admin-service` 에 `depends_on: { admin-postgres: { condition: service_healthy, required: false } }` 추가 (compose 2.20+ `required: false` 로 profile 미사용 시 무시).
  2. `POSTGRES_HOST` default를 `__SET_ME__` 로 두고 *non-with-db 모드*에서 즉시 fail-fast.
  3. 고정 네트워크 이름을 `${NETWORK_NAME:-gr-admin-net}` 로 환경화.
- 재읽기 권고 레벨: **3**.
