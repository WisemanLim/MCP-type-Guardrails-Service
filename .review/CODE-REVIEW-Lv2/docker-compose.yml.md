# docker-compose.yml — 코드 리뷰 / Code Review

> 리뷰 레벨 / Review Level: 2
> [← INDEX.md](INDEX.md)

## 파일 요약 / File Summary

- 역할 / Role: 코어 stack. Postgres + Redis + 4 서비스 (detection-engine, policy-engine, audit-service, mcp-server). 도메인 무관 *스켈레톤* 으로 phase overlay 가 환경/볼륨을 추가한다.
- 진입점에서의 거리: **0**.
- 라인 수: 182.
- 주요 export: 서비스 5개, 볼륨 3개(`pg-data`, `redis-data`, `policy-cache`), 네트워크 1개(`gr-net`).
- 의존 모듈 (internal): `scripts/init-db.sql` 마운트, `../Guardrails-Service-{Server,Policy-Engine,Audit-Service}` + `../../DA(Python,R,...)/Guardrails-Service-Detection-Engine` 의 Dockerfile.
- 사용된 외부 패키지: `postgres:16-alpine`, `redis:7-alpine`.
- 부수효과: 컨테이너·볼륨·네트워크 생성, 호스트 포트 바인딩(`5432, 6379, 8080–8083`).
- 동시성 모델: compose 가 `depends_on: condition: service_healthy` 그래프로 토폴로지 정렬 후 병렬 시동.
- 테스트 커버리지 흔적: 각 서비스 healthcheck.

## 라인 단위 분석 / Line-by-Line Analysis

### Block 1 — 헤더 주석 + `x-common-env` anchor (라인 1–29)

```yaml path=docker-compose.yml lines=1-29
# Core stack — infrastructure + all 4 services (domain-agnostic skeleton).
# Phase overlays inject domain-specific policy mounts and env:
#   P1 (privacy):  docker-compose.privacy.yml
#   P2 (food):     docker-compose.food.yml         (added when phase 2 ships)
#   P3/P4 ...      docker-compose.<domain>.yml
#
# Usage:
#   # Phase 1 only (default)
#   docker compose -f docker-compose.yml -f docker-compose.privacy.yml up -d
# ...
x-common-env: &common-env
  NODE_ENV: ${NODE_ENV:-production}
  LOG_LEVEL: ${LOG_LEVEL:-info}
  POSTGRES_HOST: postgres
  POSTGRES_PORT: 5432
  POSTGRES_DB: ${POSTGRES_DB:-guardrails}
  POSTGRES_USER: ${POSTGRES_USER:-guardrails}
  POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-guardrails}
  REDIS_HOST: redis
  REDIS_PORT: 6379
```

**분석 / Analysis (Level 2)**

- `x-` 접두 키 — compose가 *무시*하지만 YAML anchor 정의에는 영향. `x-common-env: &common-env { ... }` 는 *공통 env 묶음*에 `common-env` 라는 anchor를 붙임.
- 이후 서비스에서 `<<: *common-env` (merge key)로 *상속*. *왜:* DRY — DB/Redis 접속 정보, NODE_ENV 등을 한 곳에서 관리.
- `POSTGRES_HOST: postgres` 는 *호스트명 = 서비스명* 컴포즈 DNS 룰. `gr-net` 네트워크 내부에서 자동 해석.
- 기본 비밀이 다시 등장 — `POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-guardrails}`. `.env.example` 의 `change-me-in-prod` 와 *다른* default 가 또 박혀있어, 두 곳 중 어느 쪽이 운영자에게 보일지 모호.

**짚어볼 점 / Watch-outs**

- YAML merge key (`<<:`) 의 동작은 compose v2 에서도 지원. 단 *서비스 내 environment 키와의 충돌*은 서비스 측이 이김(override). 일관된 머지 동작 가정.
- `POSTGRES_PASSWORD` default 값이 **두 군데**(`.env.example`, 본 파일)에 *다른 placeholder*로 박힘. 운영자가 `.env` 안 만들면 `guardrails` 가 사용됨 → 약한 비밀번호. fail-fast 부재.

### Block 2 — postgres + redis 서비스 (라인 31–66)

```yaml path=docker-compose.yml lines=31-66
services:
  postgres:
    image: postgres:16-alpine
    container_name: gr-postgres
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${POSTGRES_DB:-guardrails}
      POSTGRES_USER: ${POSTGRES_USER:-guardrails}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-guardrails}
    volumes:
      - pg-data:/var/lib/postgresql/data
      - ./scripts/init-db.sql:/docker-entrypoint-initdb.d/01-init.sql:ro
    ports:
      - "${POSTGRES_EXPOSED_PORT:-5432}:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER:-guardrails} -d ${POSTGRES_DB:-guardrails}"]
      interval: 5s
      timeout: 5s
      retries: 20
    networks: [gr-net]

  redis:
    image: redis:7-alpine
    container_name: gr-redis
    restart: unless-stopped
    command: ["redis-server", "--appendonly", "yes"]
    volumes:
      - redis-data:/data
    ports:
      - "${REDIS_EXPOSED_PORT:-6379}:6379"
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 20
    networks: [gr-net]
```

**분석 / Analysis (Level 2)**

- `container_name: gr-postgres` — 컴포즈가 보통 `<project>_postgres_1` 형식의 자동 이름을 쓰지만 *고정 이름*을 강제. `make psql` 같은 명령이 어디서 호출돼도 동일 컨테이너를 가리키도록.
- `restart: unless-stopped` — Docker 데몬 재시작 시 자동 부활. `always`보다 약함 — 운영자가 명시적으로 `docker stop` 하면 부활 안 함.
- volumes 두 줄:
  - `pg-data:/var/lib/postgresql/data` — 영속 볼륨 (postgres 데이터).
  - `./scripts/init-db.sql:/docker-entrypoint-initdb.d/01-init.sql:ro` — *호스트 파일을 컨테이너에 read-only 마운트*. postgres official 이미지의 first-boot 진입점이 이 디렉토리의 `.sql` 을 알파벳 순으로 실행.
- `healthcheck` `pg_isready` — postgres가 클라이언트 연결 받을 준비가 되었는지 확인. `interval=5s × retries=20` = 최대 100초 대기.
- `redis`:
  - `command: redis-server --appendonly yes` — AOF (Append-Only File) 영속 모드. RDB snapshot 만 쓰면 *마지막 snapshot 이후* 변경이 휘발 → AOF 로 *모든 write 명령*이 기록.
  - healthcheck `redis-cli ping` → `PONG` 이면 healthy.

**짚어볼 점 / Watch-outs**

- `./scripts/init-db.sql` mount — *호스트 파일*. 운영자가 호스트 위 init.sql을 수정해도 *컨테이너 첫 부팅 이후* 에는 무의미 (postgres 가 first boot only 실행). 명백히 *시드 전용*이지 *마이그레이션 트리거*가 아니다.
- `restart: unless-stopped` + healthcheck failing — postgres 가 startup loop 에 빠지면 *조용히* 재시작 반복. 운영자가 logs 를 봐야 알 수 있음.
- Redis healthcheck 가 `redis-cli ping` — *익명* 호출. AUTH 설정이 들어가면 ping 만으로도 NOAUTH 에러로 healthy 표시 가능 (Redis 버전 의존). 현 시점 AUTH 미설정 → 무문제.

### Block 3 — detection-engine (라인 68–89)

```yaml path=docker-compose.yml lines=68-89
  detection-engine:
    build:
      context: ../../DA(Python,R,...)/Guardrails-Service-Detection-Engine
      dockerfile: Dockerfile
    container_name: gr-detection
    restart: unless-stopped
    environment:
      <<: *common-env
      PORT: 8081
      # Phase overlays append to this CSV via ENV substitution at compose merge time.
      GUARDRAILS_ENABLED_DOMAINS: ${GUARDRAILS_ENABLED_DOMAINS:-global}
      GUARDRAILS_LOCALES: ${GUARDRAILS_LOCALES:-ko-KR,en}
    ports:
      - "${DETECTION_EXPOSED_PORT:-8081}:8081"
    depends_on:
      redis: { condition: service_healthy }
    healthcheck:
      test: ["CMD", "python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://localhost:8081/health').status==200 else 1)"]
      interval: 10s
      timeout: 5s
      retries: 10
    networks: [gr-net]
```

**분석 / Analysis (Level 2)**

- `build.context: ../../DA(Python,R,...)/Guardrails-Service-Detection-Engine` — *상대 경로*로 두 단계 위 디렉토리 탐색. 디렉토리 이름의 괄호/쉼표/dot 가 셸 escape 이슈를 만들 수 있음.
- `<<: *common-env` 로 공용 env 상속. `PORT: 8081` 등 *서비스 고유 키*는 같은 environment 블록에 같이 정의 → compose 가 anchor + 추가 키를 머지.
- `depends_on: redis: { condition: service_healthy }` — Redis healthy 가 될 때까지 *시동 자체*를 대기. compose v2 의 `condition: service_healthy` 패턴. 부팅 race 회피.
- healthcheck 가 `python -c "import urllib.request..."` *one-liner* — 컨테이너에 `curl/wget` 없이도 표준 라이브러리만으로 핑. *왜:* 이미지 슬림화 가정.

**짚어볼 점 / Watch-outs**

- **build.context 의 워크스페이스 가정** — 클론·CI 환경에 따라 형제 디렉토리 구조가 다를 수 있음. Docker 빌드 시 *부모 디렉토리*가 build context 가 되어 *대량 파일을 전송* 할 수 있음(`.dockerignore` 확인 필요, 본 루트에는 보이지 않음).
- detection-engine 은 Postgres에 `depends_on` 이 *없음* — Redis만 의존. *왜:* Detection Engine 이 stateless 라는 설계 의도. 만약 향후 분류기가 DB 의존을 추가하면 여기에 의존성 추가.
- `python -c "..."` 헬스체크는 *짧은 한 줄*이지만 `urlopen` 의 기본 타임아웃이 *전역 default*. 컨테이너 부팅 직후 잠시 hang 시 false negative 가능. `urlopen(..., timeout=3)` 같이 명시 권고.

### Block 4 — policy-engine (라인 91–122)

```yaml path=docker-compose.yml lines=91-122
  policy-engine:
    build:
      context: ../Guardrails-Service-Policy-Engine
      dockerfile: Dockerfile
    container_name: gr-policy
    restart: unless-stopped
    environment:
      <<: *common-env
      PORT: 8082
      POLICY_DIR: /app/policies
      SEEDS_DIR: /app/seeds
      GUARDRAILS_ENABLED_DOMAINS: ${GUARDRAILS_ENABLED_DOMAINS:-global}
    volumes:
      # Built-in package policies (image-baked) are at /app/policies.
      # Phase overlays mount additional bundles READ-ONLY at /app/policies/<domain>.
      - policy-cache:/app/.cache
      # Flat seed bundles produced by scripts/gen-rules.py. Read-only.
      # Policy Engine ingests these on boot and (if rules table is empty for
      # a given domain) bulk-INSERTs them with source='file'. Idempotent.
      - ./scripts:/app/seeds:ro
    ports:
      - "${POLICY_EXPOSED_PORT:-8082}:8082"
    depends_on:
      postgres: { condition: service_healthy }
      redis: { condition: service_healthy }
    healthcheck:
      test: ["CMD", "node", "-e", "require('http').get('http://127.0.0.1:8082/health',r=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1))"]
      interval: 5s
      timeout: 5s
      retries: 20
      start_period: 10s
    networks: [gr-net]
```

**분석 / Analysis (Level 2)**

- `POLICY_DIR=/app/policies` + `SEEDS_DIR=/app/seeds` — 형제 NestJS 서비스가 이 환경변수를 읽어 *부팅 시 정책 적재*. 분리 이유: `POLICY_DIR`은 phase overlay가 *덧붙이는* 디렉토리, `SEEDS_DIR`은 *생 JSON*.
- `./scripts:/app/seeds:ro` — `scripts/` 전체를 마운트. JSON 4종 외 `gen-rules.py`, `init-db.sql`, `smoke.sh` 까지 함께 노출되지만 *read-only* 이므로 보안 위험 적음. 그러나 *불필요 노출*이긴 함 — 향후 더 좁힌 마운트 권고.
- `start_period: 10s` — 컨테이너 시동 직후 10초 동안은 healthcheck 실패를 *unhealthy로 간주하지 않음*. NestJS bootstrap 시간 고려.
- healthcheck `node -e "require('http').get(...).on('error',()=>process.exit(1))"` — 동기적 응답 status 만 보고 0/1 결정. 5초 timeout.

**짚어볼 점 / Watch-outs**

- `./scripts:/app/seeds:ro` 가 *디렉토리 전체* 노출 — 만약 누군가 `scripts/`에 비밀 키 파일을 떨어뜨리면 컨테이너 안에서도 접근 가능. *원칙: 필요한 파일만 마운트*.
- `policy-engine` 이 redis healthy 도 의존 — Redis 미사용 모드(`local.yml`)에서는 redis 서비스 자체가 비활성화(`profiles: ["__disabled__"]`)되어 compose가 의존 무시. 그러나 `local.yml` 의 `depends_on: !reset []` 도 같이 사용 — *이중 안전망*.

### Block 5 — audit-service + mcp-server (라인 124–173)

```yaml path=docker-compose.yml lines=124-173
  audit-service:
    build:
      context: ../Guardrails-Service-Audit-Service
      dockerfile: Dockerfile
    container_name: gr-audit
    restart: unless-stopped
    environment:
      <<: *common-env
      PORT: 8083
    ports:
      - "${AUDIT_EXPOSED_PORT:-8083}:8083"
    depends_on:
      postgres: { condition: service_healthy }
    healthcheck:
      test: ["CMD", "node", "-e", "require('http').get('http://127.0.0.1:8083/health',r=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1))"]
      interval: 5s
      timeout: 5s
      retries: 20
      start_period: 10s
    networks: [gr-net]

  mcp-server:
    build:
      context: ../Guardrails-Service-Server
      dockerfile: Dockerfile
    container_name: gr-mcp
    restart: unless-stopped
    environment:
      <<: *common-env
      PORT: 8080
      MCP_TRANSPORT: ${MCP_TRANSPORT:-http}
      POLICY_ENGINE_URL: http://policy-engine:8082
      DETECTION_ENGINE_URL: http://detection-engine:8081
      AUDIT_SERVICE_URL: http://audit-service:8083
      GUARDRAILS_ENABLED_DOMAINS: ${GUARDRAILS_ENABLED_DOMAINS:-global}
      GUARDRAILS_LOCALES: ${GUARDRAILS_LOCALES:-ko-KR,en}
      GUARDRAILS_API_KEY: ${GUARDRAILS_API_KEY:-dev-key-please-change}
    ports:
      - "${MCP_EXPOSED_PORT:-8080}:8080"
    depends_on:
      policy-engine: { condition: service_healthy }
      detection-engine: { condition: service_healthy }
      audit-service: { condition: service_healthy }
    healthcheck:
      test: ["CMD", "node", "-e", "require('http').get('http://127.0.0.1:8080/health',r=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1))"]
      interval: 5s
      timeout: 5s
      retries: 20
      start_period: 10s
    networks: [gr-net]
```

**분석 / Analysis (Level 2)**

- `audit-service` 는 *Redis 의존 없음* — 감사 로그는 *write-heavy* + 캐시 불필요.
- `mcp-server` 의 의존이 **모두** healthy 조건 — 3 서비스가 모두 응답 가능해야 부팅. 운영적으로는 *부팅 전체가 직렬화*되어 시간이 길어지지만, *“의존 미준비 상태에서 사용자가 호출”* 시나리오 방지.
- `POLICY_ENGINE_URL: http://policy-engine:8082` 등 *서비스명* 사용 — Docker compose DNS가 같은 네트워크 내부 호스트네임을 해석. `127.0.0.1`이 아니라 *peer hostname*.
- `GUARDRAILS_API_KEY` 가 *mcp-server* 에만 노출 — 다른 서비스는 receivable token 검증을 안 한다는 의미. 즉 *경계 = MCP only*.

**짚어볼 점 / Watch-outs**

- 의존 사슬이 깊음(`mcp → policy → postgres`) — 하나의 서비스 unhealthy 가 *전 stack* 부팅을 막을 수 있음. 운영 환경에서는 *graceful degrade* 옵션 고려.
- `GUARDRAILS_API_KEY` 의 default `dev-key-please-change` — 운영자가 `.env` 안 만들면 자동 적용. 권고: NODE_ENV=production + default 키 동시 감지 시 *MCP 부팅 거부*.
- 모든 healthcheck 가 `node -e` 인라인. 컨테이너에 *node* 바이너리가 있어야 동작 (서비스 컨테이너이므로 당연히 있음). 그러나 *unrelated*하게 alpine slim 이미지로 다이어트할 때 잘릴 수 있는 위험.

### Block 6 — volumes / networks (라인 175–183)

```yaml path=docker-compose.yml lines=175-183
volumes:
  pg-data:
  redis-data:
  policy-cache:

networks:
  gr-net:
    driver: bridge
```

**분석 / Analysis (Level 2)**

- `volumes:` 의 빈 값 = compose 가 *기본 driver(local)* 로 *named volume* 자동 생성.
- `gr-net` bridge — 단일 호스트의 격리 네트워크. 외부에서 서비스명으로 접근하려면 호스트 포트 매핑 필요(이 파일의 `ports:` 라인들).

**짚어볼 점 / Watch-outs**

- bridge 드라이버는 *single-host*. multi-host (swarm/k8s) 전환 시 별도 처리 필요.

## 파일 수준 평가 / File-Level Verdict

- 강점 / Strengths:
  1. **healthcheck 그래프**가 의존 토폴로지에 정확히 매핑 — 부팅 race 거의 방지.
  2. `x-common-env` anchor 로 공유 env DRY — 5 서비스에 동일 DB/Redis 정보를 한 곳에서.
  3. compose overlay 가 *base 변경 없이* phase·local·admin 변종을 만든다는 설계가 깔끔.
- 위험 / Risks:
  1. `build.context` 의 *상대 경로 형제 디렉토리 결합도* — 워크스페이스 가정 강함.
  2. `./scripts:/app/seeds:ro` 의 *디렉토리 전체* 노출.
  3. `GUARDRAILS_API_KEY` default 가 fail-fast 없음.
- 개선 권고 / Recommendations:
  1. `${WORKSPACE_ROOT}/Guardrails-Service-Server` 처럼 env 로 추상화.
  2. `./scripts/privacy.kr.json`, `./scripts/manufacturing-food.kr.json` 등 *파일 단위* 마운트(phase overlay가 이미 이렇게 함 — base 의 `:/app/seeds:ro` 는 제거 가능).
  3. compose 단계 secret (`secrets:`) 으로 비밀 분리.
- 재읽기 권고 레벨: **3** — 인프라 설계 의도까지 의식.
