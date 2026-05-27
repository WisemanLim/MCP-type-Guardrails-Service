# docker-compose.local.yml — 코드 리뷰 / Code Review

> 리뷰 레벨 / Review Level: 2
> [← INDEX.md](INDEX.md)

## 파일 요약 / File Summary

- 역할 / Role: SQLite 모드 overlay — Postgres/Redis 비활성화, Policy/Audit 서비스 SQLite 단일 파일 사용.
- 진입점에서의 거리: **1** (base + privacy + local 등 결합).
- 라인 수: 53.
- 주요 export: `postgres`/`redis` `profiles=["__disabled__"]`, `policy-engine`/`audit-service` 의 `DB_DRIVER=sqlite`, `gr-sqlite`/`audit-sqlite` 볼륨.
- 의존 모듈: `docker-compose.yml`.

## 라인 단위 분석 / Line-by-Line Analysis

### Block 1 — 주석 (라인 1–16)

```yaml path=docker-compose.local.yml lines=1-16
# Local / lightweight overlay — drops Postgres, runs Policy Engine + Audit
# Service on SQLite single-file DBs. Redis is also removed since both Policy
# Engine and MCP Server fall back to cache-less mode when Redis is missing.
#
# Combine with any phase overlay:
#   docker compose -f docker-compose.yml \
#                  -f docker-compose.privacy.yml \
#                  -f docker-compose.local.yml up -d
#
# Or skip Docker entirely and just set DB_DRIVER=sqlite in each service's
# .env, then `npm run start:dev` per service. The same code path is exercised.
#
# IMPORTANT: Policy Engine writes the `rules` table to the SHARED file
# `/app/var/guardrails.db`. Admin (when also overlaid) reads/writes the
# same file, so rule mutations are visible to both sides without an
# explicit sync step.
```

**분석 / Analysis (Level 2)**

- 주석이 *설계 의도와 사용법*을 명시 — 운영자가 *왜 local 모드인지* 와 *공유 sqlite 파일을 통한 admin↔policy 동기화* 메커니즘을 즉시 파악.

**짚어볼 점 / Watch-outs**

- “Same code path is exercised” — *형제 서비스의 fallback 코드*에 의존하는 주장. 본 파일만으로 검증 불가. 형제 코드의 회귀가 *local 모드만 깨뜨릴* 수 있는 위험.

### Block 2 — disable 패턴 + SQLite override (라인 18–53)

```yaml path=docker-compose.local.yml lines=18-53
services:
  postgres:
    profiles: ["__disabled__"]

  redis:
    profiles: ["__disabled__"]

  policy-engine:
    environment:
      DB_DRIVER: sqlite
      SQLITE_PATH: /app/var/guardrails.db
      REDIS_HOST: ""
    volumes:
      - gr-sqlite:/app/var
    depends_on: !reset []

  audit-service:
    environment:
      DB_DRIVER: sqlite
      SQLITE_PATH: /app/var/audit.db
    volumes:
      - audit-sqlite:/app/var
    depends_on: !reset []

  detection-engine:
    depends_on: !reset []

  mcp-server:
    depends_on:
      policy-engine: { condition: service_healthy }
      detection-engine: { condition: service_healthy }
      audit-service: { condition: service_healthy }

volumes:
  gr-sqlite:
  audit-sqlite:
```

**분석 / Analysis (Level 2)**

- `profiles: ["__disabled__"]` — compose의 *profile* 기능을 이용한 *조건부 활성화* 트릭. 일반 `up`은 profile 없는 서비스만 시작 → *profile이 붙은 서비스는 비활성*. 명시적 `__disabled__`는 *그 어떤 운영자도 우연히 활성화 못 하도록* 자기-문서적 이름.
- `policy-engine.environment.REDIS_HOST: ""` — 빈 문자열. 형제 코드가 `REDIS_HOST` 가 truthy 일 때만 Redis 연결을 시도하는 *fallback 설계* 전제. 빈 값으로 *명시적으로 disable*.
- `depends_on: !reset []` — **YAML tag** `!reset`. compose v2 가 지원하는 *override directive*. base 의 `depends_on` 을 *완전히 빈 배열로 재설정*. 일반 머지(append) 가 아닌 *replace*가 필요한 이유: base 가 `postgres: service_healthy` 를 명시했는데 postgres 자체가 disabled 면 compose 가 “unknown dependency” 에러를 던지기 때문.
- `mcp-server.depends_on` — base와 동일한 3-서비스 의존을 *다시* 명시. *왜:* base 의 의존은 그대로 두고 싶지만, compose 의 머지 동작상 `!reset` 을 안 쓰면 base 의 `policy-engine`/`detection-engine`/`audit-service` 의존이 정상 유지됨. 본 줄은 *의도 표시*에 가까움(중복이긴 함).
- `gr-sqlite` 가 *Policy Engine* 의 볼륨 — `admin-local.yml` 도 같은 볼륨에 마운트해 admin↔policy 공유.

**짚어볼 점 / Watch-outs**

- `!reset` YAML tag 는 *compose v2.20+ 전용*. 운영 호스트가 그 이하 버전이면 *모호한 에러*. README 에 최소 버전 명시 필요.
- `mcp-server` 의 `depends_on` 재선언이 *base와 동일* — 만약 base 가 향후 추가 의존을 받으면 *이 파일도 같이 수정*해야 머지 충돌 회피. 잠재적 *유지보수 부담*.
- `SQLITE_PATH: /app/var/guardrails.db` 가 Policy Engine + Admin 공유. *동시 write 충돌* 시 SQLite WAL 모드 사용 여부가 핵심. 형제 코드 구현 의존.

## 파일 수준 평가 / File-Level Verdict

- 강점 / Strengths:
  1. `__disabled__` profile 트릭 — *명시적 비활성*. 자기 문서.
  2. `!reset []` 으로 base 의존 정확히 끊음.
  3. 공유 sqlite 설계 의도 *주석으로 강조*.
- 위험 / Risks:
  1. `!reset` 버전 의존.
  2. `mcp-server.depends_on` 중복 선언 — base 변경 시 sync 부담.
  3. SQLite 동시 write contention 의 *런타임 검증 부재*.
- 개선 권고 / Recommendations:
  1. README/compose 첫 줄에 `# requires docker compose >= 2.20` 주석 추가.
  2. `mcp-server.depends_on` 의 *중복 선언* 제거 (base가 그대로 머지되므로 불필요한 경우 정리).
  3. SQLite 사용 시 *journal_mode=WAL* + *busy_timeout* 설정을 컨테이너 init 단계에 강제.
- 재읽기 권고 레벨: **3** — `!reset` overlay 의 합성 순서 이해 위해.
