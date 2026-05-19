# MCP-type Guardrails Service — Operating

루트는 **운영(배포·구성·통합·정책 시드·시험)** 전용. 컴포넌트 소스는 형제 디렉토리.

```
../Guardrails-Service-Server                                  # MCP Server (NestJS + TS)
../Guardrails-Service-Policy-Engine                           # Policy Engine (NestJS + TS) + 정책 번들
../Guardrails-Service-Audit-Service                           # Audit Service (NestJS + TS)
../../DA(Python,R,...)/Guardrails-Service-Detection-Engine    # Detection Engine (Python + FastAPI)
```

레퍼런스: [`.doc/PRD.md`](.doc/PRD.md), [`.doc/Perplexity-Guardrails for LLM,RAG, 도메인별.md`](.doc/), [`.doc/Perplexity-ISIC,KSIC,NACE,NAICS 분류 조사 및 정리.md`](.doc/).

---

## 디렉토리 구조

```
MCP-type-Guardrails-Service/
├── docker-compose.yml             # 코어 stack (Postgres + Redis + 4 services)
├── docker-compose.privacy.yml     # Phase 1 overlay (global/privacy)
├── docker-compose.food.yml        # Phase 2 overlay (manufacturing-food)
├── docker-compose.local.yml       # 경량 overlay (SQLite, Postgres/Redis 제거)
├── Makefile                       # up-p1 / up-p1-p2 / up-local / smoke / clean
├── .env.example
├── scripts/
│   ├── init-db.sql                # Postgres 스키마 (자동 적재)
│   ├── gen-rules.py               # 정책 룰 generator (4개 JSON 산출)
│   ├── privacy.kr.json            # Phase 1 ko-KR, 245 rules
│   ├── privacy.en.json            # Phase 1 en, 245 rules
│   ├── manufacturing-food.kr.json # Phase 2 ko-KR, 127 rules
│   ├── manufacturing-food.en.json # Phase 2 en, 127 rules
│   └── smoke.sh                   # HTTP transport 스모크
├── test/
│   ├── Guardrails-Service-Phase#1.sh       # build/deploy/test driver (13단계)
│   ├── Guardrails-Service-Phase#1-results.md
│   └── runs/<TS>/                          # 회차별 raw logs
└── .doc/                                   # PRD + 조사 자료
```

---

## 빠른 시작

```bash
cp .env.example .env

# Phase 1 (privacy) + Postgres + Redis
make up-p1
make smoke
make logs
make down
```

`http://localhost:8080`:

- `GET  /health`
- `GET  /mcp/tools`
- `POST /mcp/tools/<name>` (x-api-key 필요)
- `POST /mcp` (JSON-RPC 2.0)
- `GET  /mcp/sse` (SSE 브리지)

---

## 단계적 배포

| 단계     | 도메인                          | 명령                                                                                                       | 룰 수            |
| :------- | :------------------------------ | :--------------------------------------------------------------------------------------------------------- | ---------------: |
| P1       | `global` (privacy)              | `make up-p1`                                                                                               |  245/245 (ko/en) |
| P1 + P2  | `global` + `manufacturing-food` | `make up-p1-p2`                                                                                            | + 127/127 (ko/en) |
| P1 + P3+ | `global` + `<P3..>`             | `docker compose -f docker-compose.yml -f docker-compose.privacy.yml -f docker-compose.<phase>.yml up -d`   |       per-phase |

각 phase overlay 한 장 추가만으로 합쳐짐. 코어 `docker-compose.yml`은 phase 간 불변. 머지 우선순위 + 충돌 해소는 PRD §4.1.4.

전체 phase 로드맵 (ISIC/KSIC/NACE/NAICS 매핑): [PRD §18](.doc/PRD.md).

---

## DB 백엔드 (Postgres / SQLite)

| 모드                          | 명령           | 용도                              |
| :---------------------------- | :------------- | :-------------------------------- |
| Postgres + Redis (production) | `make up-p1`   | 정식 운영, RBAC, 감사             |
| SQLite single-file (local)    | `make up-local` | 개발, PoC, 데몬 없는 환경         |

ENV 스위치 (서비스별 자동 인식):

```bash
DB_DRIVER=postgres        # 기본
# 또는
DB_DRIVER=sqlite
SQLITE_PATH=./var/policy-engine.db   # service-side override
```

SQLite 모드는 `docker-compose.local.yml` overlay가 postgres/redis 비활성화 + 컨테이너 내 `/app/var` 볼륨 mount. Policy Engine + Audit Service 모두 동일한 `DbService` facade로 양 backend 지원 (TEXT[] / JSONB → JSON 인코딩 자동 변환).

---

## 컴포넌트 독립 구동

각 컴포넌트는 자체 `Dockerfile` + `package.json` / `pyproject.toml` 보유. 로컬 dev:

```bash
# Detection Engine (Python)
cd ../../DA\(Python,R,...\)/Guardrails-Service-Detection-Engine
python3 -m venv .venv && source .venv/bin/activate
pip install -e .[dev]
uvicorn src.main:app --port 8081 --reload

# Policy Engine
cd ../Guardrails-Service-Policy-Engine
npm install && npm run start:dev          # Postgres
DB_DRIVER=sqlite npm run start:dev        # SQLite

# Audit Service
cd ../Guardrails-Service-Audit-Service
npm install && npm run start:dev

# MCP Server
cd ../Guardrails-Service-Server
npm install && npm run start:dev                     # HTTP transport
MCP_TRANSPORT=stdio npm run start                    # stdio transport
```

---

## 정책 룰 시드

`scripts/gen-rules.py` 생성기로 4개 JSON 산출 (deterministic, idempotent):

```bash
python3 scripts/gen-rules.py
```

| 파일                          | domain               | locale  | totalRules | 카테고리                                                                                                              |
| :---------------------------- | :------------------- | :------ | ---------: | :-------------------------------------------------------------------------------------------------------------------- |
| `privacy.kr.json`             | `global`             | `ko-KR` |    **245** | pii=102, financial=27, health=26, credentials=24, location=17, sensitive=16, children=15, biometrics=8, scope=7, ... |
| `privacy.en.json`             | `global`             | `en`    |    **245** | (동일)                                                                                                                |
| `manufacturing-food.kr.json`  | `manufacturing-food` | `ko-KR` |    **127** | compliance=67, pii=30, safety=16, ip=14                                                                               |
| `manufacturing-food.en.json`  | `manufacturing-food` | `en`    |    **127** | (동일)                                                                                                                |

ruleId scheme: `<PREFIX>_<NNN>` (예: `PRIV_KR_245`, `MF_FOOD_EN_127`). 마지막 번호 = `totalRules`.

규제 태그: KR_PIPA / KR_FSC / KR_FSC_HACCP / KR_FSC_HFL / KR_FSC_PLS / KR_OSH / KR_NAQS / EU_GDPR / EU_GDPR_Art9 / EU_GDPR_Art10 / EU_1169_2011 / EU_1881_2006 / EU_396_2005 / EU_1829_2003 / EU_178_2002 / EU_2018_848 / EU_EFSA / US_HIPAA / US_CCPA / US_FDA / US_FDA_FALCPA / US_FDA_FASTER / US_FDA_FSMA / US_FDA_HACCP / US_FSIS / US_EPA / US_USDA_NOP / US_USDA_BE / JP_APPI / COPPA / PCI_DSS / WCO_HS / TRADE_SECRET / UK_NHSDigital / CA_PIPEDA / AU_Privacy / IN_DPDP / BR_LGPD.

---

## MCP 클라이언트 연결

### Claude Desktop (stdio)

```json
{
  "mcpServers": {
    "guardrails": {
      "command": "node",
      "args": ["/path/to/Guardrails-Service-Server/dist/main.js"],
      "env": {
        "MCP_TRANSPORT": "stdio",
        "POLICY_ENGINE_URL": "http://localhost:8082",
        "DETECTION_ENGINE_URL": "http://localhost:8081",
        "AUDIT_SERVICE_URL": "http://localhost:8083",
        "GUARDRAILS_ENABLED_DOMAINS": "global",
        "GUARDRAILS_LOCALES": "ko-KR,en"
      }
    }
  }
}
```

복수 도메인 (P1 + P2):

```jsonc
"env": {
  "GUARDRAILS_ENABLED_DOMAINS": "global,manufacturing-food",
  "GUARDRAILS_LOCALES": "ko-KR,en"
}
```

### Gemini CLI (`~/.gemini/settings.json`)

```json
{
  "mcpServers": {
    "guardrails": {
      "command": "node",
      "args": ["/opt/guardrails/dist/main.js"],
      "env": {
        "GUARDRAILS_ENABLED_DOMAINS": "global,manufacturing-food",
        "GUARDRAILS_LOCALES": "ko-KR,en"
      }
    }
  }
}
```

### 원격 HTTP / SSE 브리지

```json
{
  "mcpServers": {
    "guardrails": {
      "command": "npx",
      "args": ["mcp-remote", "http://localhost:8080/mcp/sse"],
      "env": { "GUARDRAILS_API_KEY": "dev-key-please-change" }
    }
  }
}
```

### 권장 시스템 프롬프트

```
You MUST call `guardrails.validate_input` on every user prompt
and `guardrails.validate_output` on every model response.

If decision == "block": stop and show message.
If decision == "redact" or "sanitize": use redactedText only.
If decision == "escalate": deliver only a generic acknowledgement.

Active domains: ${GUARDRAILS_ENABLED_DOMAINS}.
Active locales: ${GUARDRAILS_LOCALES}.
```

---

## MCP Tools (요약)

| Tool                                | 용도                                                |
| :---------------------------------- | :-------------------------------------------------- |
| `validate_input`                    | 사용자 입력 판정 (decision/risk/rules/redactedText) |
| `validate_output`                   | 모델 응답 판정 (output ruleset만 평가)              |
| `sanitize_input` / `redact_output`  | 결정 없이 정규화·마스킹만                           |
| `classify_privacy`                  | PII 카테고리 분류 (action 없음)                     |
| `get_policy_bundle`                 | compiled bundle 조회 (디버깅)                       |
| `explain_decision`                  | `decisionId` → audit 원본                           |
| `health_check`                      | 활성 도메인/locale/transport                        |

상세 스키마: [PRD §6](.doc/PRD.md).

---

## 시험

### 통합 build / deploy / verify driver

```bash
# Postgres 스택 (기본)
bash 'test/Guardrails-Service-Phase#1.sh'

# SQLite 경량 스택
DB_DRIVER=sqlite bash 'test/Guardrails-Service-Phase#1.sh'

# 이미지 재사용
SKIP_BUILD=1 bash 'test/Guardrails-Service-Phase#1.sh'

# 정리 안 함 (디버깅)
KEEP_UP=1 bash 'test/Guardrails-Service-Phase#1.sh'
```

13단계: preflight → build → up → wait-health → 4 health endpoint → policy bundle → detection /detect 6 케이스 → MCP validate 6 케이스 → JSON-RPC tools/list → Detection pytest (host) → audit recent → ps/logs → tear-down.

결과: `test/Guardrails-Service-Phase#1-results.md` (마지막 회차), `test/runs/<TS>/` (raw 로그/JSON).

### 컴포넌트별 단위 테스트

| 컴포넌트         | 명령                                                                          |
| :--------------- | :---------------------------------------------------------------------------- |
| Detection Engine | `cd ../../DA(Python,R,...)/Guardrails-Service-Detection-Engine && pytest -q` |
| Policy Engine    | `cd ../Guardrails-Service-Policy-Engine && npm test`                          |
| Audit Service    | `cd ../Guardrails-Service-Audit-Service && npm test`                          |
| MCP Server       | `cd ../Guardrails-Service-Server && npm test`                                 |

---

## 환경 변수

| 변수                          | 기본                  | 설명                                       |
| :---------------------------- | :-------------------- | :----------------------------------------- |
| `DB_DRIVER`                   | `postgres`            | `postgres` \| `sqlite`                     |
| `SQLITE_PATH`                 | service-side default  | SQLite 모드 파일 경로                      |
| `GUARDRAILS_ENABLED_DOMAINS`  | `global`              | CSV — phase overlay가 override             |
| `GUARDRAILS_LOCALES`          | `ko-KR,en`            | CSV                                        |
| `GUARDRAILS_API_KEY`          | `dev-key-please-change` | HTTP transport 헤더 `x-api-key`          |
| `MCP_TRANSPORT`               | `http`                | `http` \| `stdio`                          |
| `POSTGRES_*`                  | compose 기본          | Postgres 연결                              |
| `REDIS_*`                     | compose 기본          | 캐시 (없으면 cache-less fallback)          |
| `MCP_EXPOSED_PORT`            | `8080`                | host port mapping                          |
| `POLICY_EXPOSED_PORT`         | `8082`                |                                            |
| `DETECTION_EXPOSED_PORT`      | `8081`                |                                            |
| `AUDIT_EXPOSED_PORT`          | `8083`                |                                            |

전체 목록은 `.env.example` 참고.

---

## 운영 명령 모음 (Makefile)

```bash
make help           # 타겟 목록
make up-p1          # Postgres + Redis + Phase 1
make up-p1-p2       # + Phase 2 overlay
make up-local       # SQLite (no postgres/redis)
make down           # Postgres 스택 종료
make down-local     # SQLite 스택 종료
make logs           # 전체 로그 tail
make ps             # 컨테이너 상태
make build          # 모든 이미지 빌드
make rebuild        # --no-cache 빌드
make psql           # psql 셸
make redis-cli      # Redis CLI
make smoke          # scripts/smoke.sh 실행
make clean          # down -v --remove-orphans
```

---

## 보안 요약

- HTTP transport: API Key (`x-api-key`), 추후 OAuth 2.0 Client Credentials
- stdio transport: OS 권한 의존
- 원문 비저장 기본 (`text_hash` SHA-256만)
- 다중 도메인 충돌 해소: 더 엄격한 action 우선 (`block` > `redact` > `warn` > `allow`)
- 정책 reload 동시성: Redis distributed lock (Postgres 모드)
- 자세한 보안 요구사항: [PRD §9](.doc/PRD.md).

---

## 산업분류 매핑 (도메인 키)

PRD §18에 ISIC Rev.4 / KSIC / NACE Rev.2 / NAICS 매핑 표 + Phase 1~10+ 단계별 로드맵 정리. 예시:

| `domain_key`                 | ISIC  | KSIC  | NACE  | NAICS       | 상태       |
| :--------------------------- | :---- | :---- | :---- | :---------- | :--------- |
| `global`                     | —     | —     | —     | —           | ✅ GA (P1) |
| `manufacturing-food`         | 10    | 10    | 10    | 311         | 🛠 P2      |
| `manufacturing-chemical`     | 20    | 20    | 20    | 325         | P3         |
| `manufacturing-pharma`       | 21    | 21    | 21    | 3254        | P4         |
| `manufacturing-automotive`   | 29    | 30    | 29    | 3361-3363   | P5         |
| `finance-banking`            | 64    | 64    | 64    | 522         | P7         |
| `healthcare-clinical`        | 86    | 86    | 86    | 621-622     | P8         |
| ...                          |       |       |       |             |            |

전체 표: [PRD §18.1](.doc/PRD.md).
