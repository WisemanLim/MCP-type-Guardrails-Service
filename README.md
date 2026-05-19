# MCP-type Guardrails Service — Operating

루트는 **운영(배포·구성·통합·정책 시드·시험)** 전용. 컴포넌트 소스는 형제 디렉토리.

```
../Guardrails-Service-Server                                  # MCP Server (NestJS + TS)
../Guardrails-Service-Policy-Engine                           # Policy Engine (NestJS + TS) + 정책 번들
../Guardrails-Service-Audit-Service                           # Audit Service (NestJS + TS)
../Guardrails-Service-Admin                                   # Admin API (NestJS + TS) — opt-in
../Guardrails-Service-Admin-Web                               # Admin Console (Next.js 14) — opt-in
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
├── docker-compose.admin.yml       # Admin overlay — main stack과 co-located
├── docker-compose.admin-local.yml # Admin local 모드 override (admin + local 동시 사용 시)
├── docker-compose.admin-standalone.yml  # Admin standalone (독립 호스트 배포)
├── docker-compose.admin-web.yml   # Admin Console (Next.js) overlay
├── Makefile                       # up-p1[-local] / up-p1-admin[-local] / up-p1-admin-web[-local] / ...
├── .env.example
├── scripts/
│   ├── init-db.sql                # Postgres 스키마 (자동 적재) — rules + admin tables 포함
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

명령은 **production** (postgres + redis)과 **local** (sqlite 단독) 두 모드로 분리. `-local` suffix가 없으면 production, 있으면 local.

```bash
cp .env.example .env

# Production — phase 1 (postgres + redis)
make up-p1
make smoke
make logs
make down

# Local — 동일 phase 1을 SQLite로 (postgres / redis 없음)
make up-p1-local
make smoke
make down-local
```

`http://localhost:8080` (MCP):

- `GET  /health`
- `GET  /mcp/tools`
- `POST /mcp/tools/<name>` (x-api-key 필요)
- `POST /mcp` (JSON-RPC 2.0)
- `GET  /mcp/sse` (SSE 브리지)

Admin API + Web Console 포함 기동 (옵션):

```bash
# Production (Postgres + Redis)
make up-p1-admin           # alias: make up-admin       (Phase 1 + Admin API)
make up-p1-admin-web       # alias: make up-admin-web   (Phase 1 + Admin API + Web)

# Local (SQLite)
make up-p1-admin-local     # alias: make up-admin-local
make up-p1-admin-web-local # alias: make up-admin-web-local

curl http://localhost:8084/admin/health
open http://localhost:3001
```

`http://localhost:8084` (Admin API, opt-in):

- `GET  /admin/health`
- `POST /admin/auth/register` (이메일+비밀번호+TOTP QR)
- `POST /admin/auth/login`
- `GET  /admin/auth/me`, `/admin/auth/totp/qr`, `POST /admin/auth/totp/enable`
- `GET  /admin/audit/login-history`, `/admin/audit/actions`
- `GET|POST|PUT|DELETE /admin/rules*` — 카테고리별 룰 CRUD + CSV import + bulk delete

`http://localhost:3001` (Admin Console, opt-in, Next.js):

- `/login` `/register` — 이메일/비밀번호 + TOTP QR 화면
- `/dashboard` — KPI(룰 수/도메인 분포) + 최근 로그인 / 행위 감사
- `/rules` — 필터(domain/locale/io/category) + 페이지네이션 + 체크박스 벌크 삭제 + 단건 편집·삭제
- `/rules/new` `/rules/[ruleId]` — JSON 컬럼 편집 폼
- `/rules/import` — CSV 업로드 + 거부 row 리포트
- `/audit` — 로그인 / 행위 탭
- `/users` — super_admin only
- `/settings` — TOTP enable + 비밀번호 변경

---

## 단계적 배포 — 명령 매트릭스

모든 명령은 **Phase × Suffix** 조합으로 자동 생성. 패턴:

```
up-<phase>[-<suffix>]
down-<phase>[-<suffix>]
```

- **Phase**: `p1` (privacy), `p1-p2` (+ manufacturing-food). 향후 `p1-p2-p3` 등 확장
- **Suffix** (생략 가능, 조합 순서 고정):
  - 없음 → main stack만
  - `admin` → + Admin API
  - `admin-web` → + Admin API + Admin Web (Web은 Admin 필수)
  - `local` → SQLite 모드 (Postgres/Redis 제거)
  - `admin-local`, `admin-web-local` → admin/web을 local 모드로

### 전체 24 타겟 매트릭스 (12 up + 12 down)

| Phase | Production (기본, Postgres+Redis) | Local (SQLite) |
| :-- | :-- | :-- |
| P1 | `make up-p1` | `make up-p1-local` |
| P1 + Admin | `make up-p1-admin` *(=`up-admin`)* | `make up-p1-admin-local` *(=`up-admin-local`)* |
| P1 + Admin + Web | `make up-p1-admin-web` *(=`up-admin-web`)* | `make up-p1-admin-web-local` *(=`up-admin-web-local`)* |
| P1 + P2 | `make up-p1-p2` | `make up-p1-p2-local` |
| P1 + P2 + Admin | `make up-p1-p2-admin` | `make up-p1-p2-admin-local` |
| P1 + P2 + Admin + Web | `make up-p1-p2-admin-web` | `make up-p1-p2-admin-web-local` |

각 `up-*`는 동일 이름의 `down-*` 짝을 가짐 (`down-p1-p2-admin-web-local` 등). `-local` 포함 시 `down`은 자동으로 `-v` 적용 → SQLite 볼륨 제거.

룰 수 (DB 자동 시드): P1 = 245/245 (ko/en), P2 = +127/127 (ko/en). 부팅 시 `seedIfNeeded()`가 비어있는 도메인에만 `INSERT OR IGNORE`로 적재 → custom 룰 보존.

**모드 구분 원칙**
- **Production** (default): Postgres + Redis. `-local` suffix 없음
- **Local**: SQLite 단독, daemon 없음. `-local` suffix
- **Standalone**: Admin이 main stack과 독립 운영. 별도 섹션

**Alias 규칙**
- `make up-admin` ≡ `make up-p1-admin`
- `make up-admin-web` ≡ `make up-p1-admin-web`
- `make up-admin-local` ≡ `make up-p1-admin-local`
- `make up-admin-web-local` ≡ `make up-p1-admin-web-local`
- Admin-Web은 항상 Admin을 포함 (Web → Admin API 의존)
- `down-*` 패밀리는 `up-*`와 1:1 대응

**생성된 전체 타겟 목록 확인**

```bash
make list-targets    # 24개 up/down 정렬 출력
make help            # 카테고리별 요약
```

**Only 패밀리** — main stack 기동 후 Admin/Web만 lifecycle 제어:

| 명령 | 효과 |
| :-- | :-- |
| `make up-admin-only` / `down-admin-only` | admin-service만 (re)생성/종료 (production) |
| `make up-admin-only-local` / `down-admin-only-local` | 동일, local 모드 |
| `make up-admin-web-only` / `down-admin-web-only` | admin + admin-web만 (production) |
| `make up-admin-web-only-local` / `down-admin-web-only-local` | 동일, local 모드 |

각 phase overlay 한 장 추가만으로 합쳐짐. 코어 `docker-compose.yml`은 phase 간 불변. 머지 우선순위 + 충돌 해소는 PRD §4.1.4.

전체 phase 로드맵 (ISIC/KSIC/NACE/NAICS 매핑): [PRD §18](.doc/PRD.md).

---

## DB 백엔드 (Postgres / SQLite)

| 모드 | Phase 1 명령 | 용도 |
| :-- | :-- | :-- |
| Production (Postgres + Redis) | `make up-p1` | 정식 운영, RBAC, 감사 |
| Local (SQLite 단독) | `make up-p1-local` | 개발, PoC, 데몬 없는 환경 |
| Production + Admin | `make up-p1-admin` | 운영 + 자가 관리 콘솔 API |
| Local + Admin | `make up-p1-admin-local` | 가벼운 PoC + Admin |
| Local + Admin + Web | `make up-p1-admin-web-local` | 가장 가벼운 풀 스택 (4 컨테이너) |

ENV 스위치 (서비스별 자동 인식):

```bash
DB_DRIVER=postgres        # 기본
# 또는
DB_DRIVER=sqlite
SQLITE_PATH=./var/policy-engine.db   # service-side override
```

SQLite 모드는 `docker-compose.local.yml` overlay가 postgres/redis 비활성화 + 컨테이너 내 `/app/var` 볼륨 mount. Policy Engine + Audit Service + Admin 모두 동일한 `DbService` facade로 양 backend 지원 (TEXT[] / JSONB → JSON 인코딩 자동 변환).

---

## Admin (API + Web Console, 옵션 컴포넌트)

기본 배포 미포함. Admin은 **API 서버 (NestJS, 포트 8084)**와 **웹 콘솔 (Next.js 14, 포트 3001)** 두 부분으로 구성. 각 부분 독립 up/down 가능. 동일 호스트의 main stack과 co-locate 하거나 완전히 다른 호스트에 standalone 배포할 수 있음.

### 모드 A — Co-located (main stack 안에 함께)

`docker-compose.admin.yml`이 main stack 위에 overlay. Postgres/Redis 공유.

```bash
# 풀 스택 (main + admin) 한 번에
make up-admin              # = make up-p1-admin
make down-admin            # 전체 종료

# main stack은 그대로 두고 admin-service만 추가/교체/제거
make up-admin-only         # admin-service만 (re)생성 (--no-deps), 다른 서비스 안 건드림
make restart-admin         # admin-service만 재시작
make down-admin-only       # admin-service만 종료
```

### 모드 B — Standalone (외부 DB / Policy Engine)

`docker-compose.admin-standalone.yml`은 main과 별도 compose. 같은 호스트의 다른 네트워크에서, 혹은 완전히 다른 호스트에서 운영 가능. 외부 Postgres + 외부 Policy Engine을 ENV로 지정.

```bash
POSTGRES_HOST=db.internal \
POSTGRES_PASSWORD=*** \
POLICY_ENGINE_URL=https://policy.guardrails.internal \
ADMIN_JWT_SECRET=*** \
make up-admin-standalone

make smoke-admin-standalone
make down-admin-standalone
```

### 모드 C — Standalone + 자체 Postgres 동봉

격리 환경에서 외부 DB 없이 Admin만 1대 운영. `--profile with-db`가 활성화되어 별도 Postgres가 함께 기동 (host port 5433 — main stack 5432와 충돌 방지).

```bash
make up-admin-standalone-db
make smoke-admin-standalone
make down-admin-standalone
```

### 모드 D — Admin Web Console (Next.js)

`docker-compose.admin-web.yml` overlay가 Admin API와 페어로 동작하는 Next.js 콘솔을 추가. 브라우저는 호스트 포트 8084로 Admin API를 직접 호출하므로 container 간 의존 없음 → main / standalone 어느 compose 위에도 결합 가능.

```bash
# main + admin API + Admin Web (포트 3001)
make up-admin-web
make smoke-admin-web           # GET /login → HTTP 코드 확인
make admin-web-logs

# admin-web만 (re)생성 / 종료 (main + admin은 그대로)
make up-admin-web-only
make restart-admin-web
make down-admin-web-only

# 풀 스택 종료
make down-admin-web

# standalone Admin + Web (다른 호스트 / VPN)
ADMIN_WEB_API_BASE_URL=https://admin.guardrails.example.com \
make up-admin-standalone-web
```

브라우저: `http://localhost:3001`. JWT는 localStorage에 저장, 401 응답 시 자동 로그아웃.

### 모드 E — 로컬 dev (Docker 없음, SQLite)

```bash
# Admin API
cd ../Guardrails-Service-Admin
npm install
DB_DRIVER=sqlite SQLITE_PATH=./var/admin.db npm run start:dev    # → :8084

# Admin Web (별도 터미널)
cd ../Guardrails-Service-Admin-Web
npm install
npm run dev                                                       # → :3001
```

### 모드 비교

| 모드 | 명령 | DB | Policy Engine | 영향 범위 |
| :-- | :-- | :-- | :-- | :-- |
| Co-located (full) | `make up-admin` | shared Postgres | shared (compose) | 풀 스택 up/down |
| Co-located (admin only) | `make up-admin-only` / `make down-admin-only` | shared | shared | admin-service만 |
| Co-located + Web | `make up-admin-web` | shared | shared | + admin-web |
| Co-located Web only | `make up-admin-web-only` / `make down-admin-web-only` | shared | shared | admin-web만 |
| Standalone (external) | `make up-admin-standalone` | external (ENV) | external (ENV) | admin-service만 |
| Standalone + DB | `make up-admin-standalone-db` | bundled (5433) | external (ENV) | admin + admin-postgres |
| Standalone + Web | `make up-admin-standalone-web` | external | external | admin + admin-web |
| Local dev | `npm run start:dev` | SQLite | external (ENV) | host process |

### 인증 흐름

```text
1. POST /admin/auth/register {email, password}
   → totp.qrDataUrl (PNG data URL) + totp.otpauth + totp.secret 반환
2. Authenticator 앱에서 QR 스캔
3. POST /admin/auth/totp/enable {totp: "123456"}
   → TOTP gate 활성화
4. POST /admin/auth/login {email, password, totp}
   → { token, tokenType: "Bearer", expiresIn }
5. 이후 호출: Authorization: Bearer <token>
```

부트스트랩 super_admin (첫 부팅 시 1회):

```bash
ADMIN_BOOTSTRAP_EMAIL=admin@yourorg.com
ADMIN_BOOTSTRAP_PASSWORD=long-and-secret
```

### 주요 엔드포인트

| Method | Path | Role | 설명 |
| :-- | :-- | :-- | :-- |
| POST | `/admin/auth/register` | public | 가입 + TOTP QR 발급 |
| POST | `/admin/auth/login` | public | 로그인 → JWT |
| GET | `/admin/auth/me` | Bearer | 본인 프로필 |
| POST | `/admin/auth/totp/enable` | Bearer | 6자리 코드로 TOTP gate ON |
| POST | `/admin/auth/password` | Bearer | 비밀번호 변경 |
| GET | `/admin/audit/login-history?limit=&userId=` | Bearer | 로그인 히스토리 |
| GET | `/admin/audit/actions?limit=&action=&actorId=` | Bearer | 행위 감사 로그 (자동 기록) |
| GET | `/admin/rules?domain=&locale=&ioType=&category=&enabledOnly=&limit=&offset=` | Bearer | 룰 리스트 (카테고리별 필터) |
| GET | `/admin/rules/:ruleId` | Bearer | 단일 룰 조회 |
| POST | `/admin/rules` | admin+ | 단건 추가 |
| POST | `/admin/rules/bulk` | admin+ | 다건 upsert |
| POST | `/admin/rules/import-csv` | admin+ | CSV 대량 import (multipart, 헤더 필수) |
| PUT | `/admin/rules/:ruleId` | admin+ | 수정 |
| DELETE | `/admin/rules/:ruleId` | admin+ | 단건 삭제 |
| DELETE | `/admin/rules` | admin+ | 다건 삭제 (`{ ruleIds: [...] }` body) |

`viewer` 역할은 모든 mutation에서 `403 viewer_cannot_write`. `super_admin`만 `/admin/users` + 타인 audit 조회 가능. 모든 mutating 요청은 `AuditInterceptor`가 `admin_audit_log` 자동 기록 (password/token 필드는 자동 strip).

### CSV 포맷 (헤더 필수, 대소문자 구분)

```
ruleId,domain,locale,ioType,category,subCategory,severity,priority,action,patternBundle,messageTemplate,regulationTags,examplesPositive,examplesNegative,enabled,version
```

JSON 컬럼은 valid JSON 또는 pipe(`|`) 구분 문자열. 예시:

```
PRIV_KR_999,global,ko-KR,input,pii,national_id_kr,critical,950,block,{},{"ko-KR":"주민번호 차단"},KR_PIPA|EU_GDPR,예시,반례,1,1.0.0
```

### Rule mutation → Policy Engine 반영

Admin은 모든 CRUD 후 `POST /policies/invalidate`를 Policy Engine에 호출. Policy Engine은 Redis bundle 캐시 flush + 파일+DB rules 재로드 → 다음 `validate_*` 호출부터 즉시 반영. Admin은 `rules` 테이블에 직접 쓰며 `source='admin'` 또는 `'csv'`로 마킹. 파일 시드(`source='file'`)와 동일 `ruleId`일 경우 DB rule이 override.

자세한 내용: [`../Guardrails-Service-Admin/README.md`](../Guardrails-Service-Admin/README.md).

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

# Admin API (opt-in, 독립 배포 가능)
cd ../Guardrails-Service-Admin
npm install && npm run start:dev                     # → :8084

# Admin Web (Next.js, opt-in)
cd ../Guardrails-Service-Admin-Web
npm install && npm run dev                           # → :3001
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

파일 시드 외에도, Admin API로 추가/수정한 룰은 `rules` 테이블에 저장되어 Policy Engine이 boot/invalidate 시 자동 머지.

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
| Admin            | `cd ../Guardrails-Service-Admin && npm test`                                  |
| Admin Web        | `cd ../Guardrails-Service-Admin-Web && npm run build` (build = smoke test)    |

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
| `ADMIN_EXPOSED_PORT`          | `8084`                | Admin API host port                        |
| `ADMIN_JWT_SECRET`            | `change-me-in-prod`   | JWT 서명 키 (Admin)                        |
| `ADMIN_JWT_EXPIRES_IN`        | `12h`                 | JWT 만료                                   |
| `ADMIN_BCRYPT_ROUNDS`         | `10`                  | 비밀번호 해싱 rounds                       |
| `ADMIN_TOTP_ISSUER`           | `Guardrails-Admin`    | Authenticator 앱 표시명                    |
| `ADMIN_BOOTSTRAP_EMAIL`       | (empty)               | 첫 부팅 super_admin 시드 (옵션)            |
| `ADMIN_BOOTSTRAP_PASSWORD`    | (empty)               | 첫 부팅 super_admin 시드 (옵션)            |
| `ADMIN_SQLITE_PATH`           | `/app/var/admin.db`   | SQLite 모드 admin DB 경로                  |
| `ADMIN_WEB_EXPOSED_PORT`      | `3001`                | Admin Console host port                    |
| `ADMIN_WEB_API_BASE_URL`      | `http://localhost:8084` | 브라우저가 호출할 Admin API URL (build-time 주입) |

전체 목록은 `.env.example` 참고.

---

## 운영 명령 모음 (Makefile)

```bash
make help                       # 타겟 전체 목록 (섹션 분류)

# ── Main stack ────────────────────────────────────────────
make up-p1                      # Postgres + Redis + Phase 1
make up-p1-p2                   # + Phase 2 overlay (food)
make up-local                   # SQLite mode (no postgres/redis)
make down                       # main stack 종료
make down-local                 # SQLite 스택 종료

# ── Admin co-located ──────────────────────────────────────
make up-admin                   # main + admin API (= up-p1-admin)
make up-admin-only              # admin-service만 (re)생성 (--no-deps)
make restart-admin              # admin-service만 restart
make down-admin                 # main + admin 모두 종료
make down-admin-only            # admin-service만 종료

# ── Admin Web (Next.js Console) ──────────────────────────
make up-admin-web               # main + admin API + Web (포트 3001)
make up-admin-web-only          # admin-web만 (re)생성 (--no-deps)
make restart-admin-web          # admin-web만 restart
make down-admin-web             # 전체 종료
make down-admin-web-only        # admin-web만 종료
make up-admin-standalone-web    # standalone Admin + Web (외부 host)

# ── Admin standalone ──────────────────────────────────────
make up-admin-standalone        # 외부 DB + 외부 Policy Engine 지정 (env)
make up-admin-standalone-db     # 자체 Postgres 동봉 (host port 5433)
make down-admin-standalone      # standalone 종료

# ── Diagnostics ───────────────────────────────────────────
make logs                       # main stack 전체 로그
make admin-logs                 # co-located admin-service 로그
make admin-web-logs             # admin-web 로그
make admin-standalone-logs      # standalone admin-service 로그
make ps                         # main stack ps
make ps-admin                   # main+admin overlay ps
make ps-standalone              # standalone ps
make smoke                      # MCP HTTP smoke
make smoke-admin                # /admin/health (co-located)
make smoke-admin-web            # admin-web /login HTTP 코드
make smoke-admin-standalone     # /admin/health (standalone)

# ── Build / data plane ────────────────────────────────────
make build                      # 모든 이미지 빌드
make rebuild                    # --no-cache
make build-admin                # admin API 이미지만
make build-admin-web            # admin-web 이미지만
make psql                       # psql 셸
make redis-cli                  # Redis CLI
make test                       # per-service test 안내
make clean                      # 모든 스택 down -v --remove-orphans
```

배포 매트릭스:

| Compose files                                                                                                  | 활성 컨테이너                                                | 용도                              |
| :------------------------------------------------------------------------------------------------------------- | :----------------------------------------------------------- | :-------------------------------- |
| `docker-compose.yml + privacy.yml`                                                                             | postgres, redis, mcp, policy, detection, audit               | P1 운영                           |
| `+ food.yml`                                                                                                   | + (P2 도메인 활성)                                           | P1+P2 운영                        |
| `+ local.yml`                                                                                                  | mcp, policy, detection, audit (SQLite, no daemon)            | 로컬 PoC                          |
| `+ admin.yml` (co-located)                                                                                     | + admin                                                       | 운영 + 관리 API                   |
| `+ admin.yml + admin-web.yml`                                                                                  | + admin + admin-web (3001)                                    | 운영 + 관리 API + Web 콘솔        |
| `admin-standalone.yml` (alone)                                                                                 | admin-service                                                 | Admin 단독 (외부 DB/Policy 사용) |
| `admin-standalone.yml --profile with-db`                                                                       | admin-service + admin-postgres                                | Admin + 자체 DB 동봉              |
| `admin-standalone.yml + admin-web.yml`                                                                         | admin + admin-web                                              | 독립 호스트 Admin + Web           |
| `privacy.yml + admin.yml + food.yml`                                                                           | 모두 결합                                                     | P1+P2+Admin                       |
| `privacy.yml + admin.yml + admin-web.yml + food.yml`                                                           | 모두 결합 + Web                                                | P1+P2+Admin+Web                   |

---

## 보안 요약

- HTTP transport: API Key (`x-api-key`), 추후 OAuth 2.0 Client Credentials
- stdio transport: OS 권한 의존
- Admin: bcrypt 비밀번호 + TOTP + JWT Bearer, `viewer/admin/super_admin` 역할, mutating 요청 자동 audit
- Admin Web: JWT localStorage (프로토타입), `AuthGuard`로 보호된 라우트, 401 시 자동 세션 정리, role 기반 사이드바
- 원문 비저장 기본 (`text_hash` SHA-256만)
- 다중 도메인 충돌 해소: 더 엄격한 action 우선 (`block` > `redact` > `warn` > `allow`)
- 정책 reload 동시성: Redis distributed lock (Postgres 모드)
- Admin / Admin Web 모두 기본 배포 미포함 (opt-in overlay) → 공격 표면 최소화
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
