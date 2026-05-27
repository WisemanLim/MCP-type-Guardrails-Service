# docker-compose.admin.yml — 코드 리뷰 / Code Review

> 리뷰 레벨 / Review Level: 2
> [← INDEX.md](INDEX.md)

## 파일 요약 / File Summary

- 역할 / Role: `admin-service` 를 core stack에 추가하는 overlay. JWT/TOTP/Bcrypt env, postgres+policy-engine 의존.
- 진입점에서의 거리: **1**.
- 라인 수: 59.
- 주요 export: `admin-service` 서비스, `admin-data` 볼륨.

## 라인 단위 분석 / Line-by-Line Analysis

```yaml path=docker-compose.admin.yml lines=1-60
# Opt-in Admin overlay — adds `admin-service` to the core stack.
# ...
services:
  admin-service:
    build:
      context: ../Guardrails-Service-Admin
      dockerfile: Dockerfile
    container_name: gr-admin
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
      POSTGRES_HOST: postgres
      POSTGRES_PORT: 5432
      POSTGRES_DB: ${POSTGRES_DB:-guardrails}
      POSTGRES_USER: ${POSTGRES_USER:-guardrails}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-guardrails}
      POLICY_ENGINE_URL: http://policy-engine:8082
    ports:
      - "${ADMIN_EXPOSED_PORT:-8084}:8084"
    volumes:
      - admin-data:/app/var
    depends_on:
      postgres: { condition: service_healthy }
      policy-engine: { condition: service_healthy }
    healthcheck:
      test: ["CMD", "node", "-e", "require('http').get('http://127.0.0.1:8084/admin/health',r=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1))"]
      interval: 5s
      timeout: 5s
      retries: 20
      start_period: 10s
    networks: [gr-net]

volumes:
  admin-data:
```

**분석 / Analysis (Level 2)**

- `<<: *common-env` 미사용 — base의 anchor는 *같은 파일 내*에서만 유효. overlay 파일에는 anchor 가 보이지 않으므로 *공통 env 가 일일이 다시 박힌다*. compose 한계.
- `JWT_SECRET / BCRYPT_ROUNDS / TOTP_ISSUER` — admin 서비스의 인증 핵심 파라미터. 본 overlay 에서 `.env` 키를 *컨테이너 env*로 매핑.
- `ADMIN_BOOTSTRAP_EMAIL/PASSWORD` 빈 default — `.env` 에서 둘 다 채워지면 *첫 부팅에만* super_admin 시드. 그 외엔 노옵.
- `ADMIN_CORS_ORIGINS` — Admin Web 으로부터의 CORS 정책. 빈 값일 때 *기본 deny* 인지 *기본 allow* 인지는 서비스 코드 의존.
- `POLICY_ENGINE_URL: http://policy-engine:8082` — *컴포즈 DNS* 통한 내부 호출. `gr-net` 네트워크에 함께 속해야 작동.
- `depends_on` 두 항목 — Postgres + Policy Engine healthy 조건. Postgres는 Admin DB 용, Policy Engine 은 *룰 CRUD가 prevention/race 없이 적용*되도록.
- healthcheck path `/admin/health` — mcp/policy/audit 가 모두 `/health` 인 것과 비대칭. *왜:* admin은 *path prefix* `/admin` 으로 mount 한 NestJS 모듈 구조이거나, 또는 mcp/policy 와의 라우팅 충돌 회피.

**짚어볼 점 / Watch-outs**

- `JWT_SECRET` default `change-me-in-prod` — 다시 등장. fail-fast 부재.
- `POSTGRES_PASSWORD` default `guardrails` — base 의 동일 default와 일치. *별도 비밀 분리 부재*.
- `POLICY_ENGINE_URL` 이 *상수* (env 변수 X) — Admin standalone 모드에서는 standalone overlay가 *override*. base + admin.yml 조합에서는 *항상 컴포즈 DNS*로 가정.
- `admin-data:/app/var` 볼륨이 *Postgres 모드*에서는 거의 사용 안 됨 (DB는 postgres 컨테이너에). 그러나 SQLite 모드 전환 시(`admin-local.yml`) 같은 마운트 포인트 `/app/var` 를 *다른 볼륨*(`gr-sqlite`)로 덮어쓴다 — overlay 합성 순서가 중요.

## 파일 수준 평가 / File-Level Verdict

- 강점 / Strengths:
  1. 기본 stack 과 *완전 디커플링* — admin 미사용 환경에선 overlay 자체를 빼면 됨.
  2. JWT/TOTP/Bcrypt 파라미터를 *전부* env 로 외부화.
- 위험 / Risks:
  1. 비밀 default 가 fail-fast 없음.
  2. anchor `<<: *common-env` 가 overlay 에서 동작 안 함 → 공용 env 가 *복붙 형식*.
- 개선 권고 / Recommendations:
  1. Admin 부팅 시 `NODE_ENV=production + JWT_SECRET=change-me-in-prod` 감지 시 *즉시 종료*.
  2. *공통 env* 를 별도 yaml 파일로 분리해 base/admin 양쪽에서 `extends` 또는 `include` (compose 2.20+).
- 재읽기 권고 레벨: **2**.
