# scripts/init-db.sql — 코드 리뷰 / Code Review

> 리뷰 레벨 / Review Level: 2
> [← INDEX.md](../INDEX.md)

## 파일 요약 / File Summary

- 역할 / Role: Postgres 초기 스키마 (11 테이블 + 6 인덱스 + 1 seed row). Postgres 컨테이너 첫 부팅 시 `docker-entrypoint-initdb.d/01-init.sql` 로 자동 실행.
- 진입점에서의 거리 / Distance from entrypoint: **0** (compose mount).
- 라인 수 / LOC: 172.
- 주요 export / Exports (테이블): `tenants`, `domains`, `rules`, `policy_versions`, `whitelists`, `decision_events`, `api_keys`, `test_cases`, `admin_users`, `admin_login_history`, `admin_audit_log`.
- 의존 모듈 / Depends on (internal): 없음 (스키마 자체). 형제 서비스 코드가 *이 컬럼 이름·타입·enum 값*에 맞춰 ORM/SQL 작성.
- 사용된 외부 패키지 / External: `pgcrypto` Postgres extension (`gen_random_uuid`).
- 부수효과 / Side effects: DDL — 테이블·인덱스·확장 생성. INSERT 1건 (`global` 도메인 seed).
- 동시성 모델: N/A (one-shot init).
- 테스트 커버리지 흔적: 없음. compose healthcheck 가 *기동 성공 여부*만 검증.

## 라인 단위 분석 / Line-by-Line Analysis

### Block 1 — Extension + tenants + domains (라인 1–23)

```sql path=scripts/init-db.sql lines=1-23
-- Initial schema for Guardrails Service.
-- Loaded by Postgres entrypoint on first boot.

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

CREATE TABLE IF NOT EXISTS tenants (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name        TEXT NOT NULL UNIQUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS domains (
  domain_key       TEXT PRIMARY KEY,
  parent_key       TEXT REFERENCES domains(domain_key),
  display_name     JSONB NOT NULL DEFAULT '{}'::jsonb,
  description      TEXT,
  default_locales  TEXT[] NOT NULL DEFAULT ARRAY['ko-KR','en']::TEXT[],
  regulation_tags  TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
  status           TEXT NOT NULL CHECK (status IN ('active','beta','deprecated')) DEFAULT 'active',
  inherits_from    TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
  version          TEXT NOT NULL DEFAULT '0.0.1',
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

**분석 / Analysis (Level 2)**

- `CREATE EXTENSION IF NOT EXISTS "pgcrypto"` — `gen_random_uuid()` 함수 제공. Postgres 13+ 에서는 코어에 `gen_random_uuid()`가 들어왔지만, 본 파일은 Postgres 16-alpine 사용임에도 *명시적*으로 `pgcrypto` 를 활성화. 호환성 마진 확보.
- `tenants` — 멀티 테넌시 기본 테이블. `id` UUID 기본키, `name` UNIQUE. `created_at` 은 timezone-aware (`TIMESTAMPTZ`).
- `domains.domain_key` — *TEXT primary key* (UUID 아님). PRD 의 도메인 이름(`global`, `manufacturing-food`, …)을 자연키로 사용. 외부 자료(JSON 번들의 `domain` 필드)와 *문자열 일치*가 contract.
- `parent_key REFERENCES domains(domain_key)` — 자기참조 FK. 도메인 계층(예: `manufacturing-food → manufacturing`).
- `display_name JSONB` — i18n 표시명 저장 (`{"ko-KR":"공통(전역)","en":"Global"}` 등).
- `default_locales TEXT[]` + `regulation_tags TEXT[]` + `inherits_from TEXT[]` — Postgres array 타입. *왜:* 정적 enum 외 자유로운 다중값을 컬럼 한 개로 표현 + indexable.
- `status` 의 CHECK 제약 — Postgres가 *DDL 단계*에서 enum 강제. 이후 ALTER로 enum 확장 시 변경 필요.

**짚어볼 점 / Watch-outs**

- `TEXT[]` 컬럼은 `&&` (overlap) / `@>` (contains) 등 array operator 사용 가능. 그러나 *GIN 인덱스*가 명시되지 않음 → 다량 데이터에서 array 검색이 seq scan으로 갈 수 있음 (현 시점에는 작음 → 무시 가능).
- `display_name JSONB DEFAULT '{}'::jsonb` — 빈 JSON 객체 default. 서비스 측이 빈 객체일 때 *fallback locale*을 어떻게 정할지 사양에 명시되어야 함.
- `domains` 에 *seed row* 가 단 1개 (`global`, 라인 164–172). 다른 도메인은 Policy Engine 가 *JSON 번들 적재 시 자동 INSERT*해야 함 — 그 코드는 형제 디렉토리.

### Block 2 — rules + 인덱스 + hot-patch ALTER (라인 25–49)

```sql path=scripts/init-db.sql lines=25-49
CREATE TABLE IF NOT EXISTS rules (
  rule_id           TEXT PRIMARY KEY,
  domain            TEXT NOT NULL REFERENCES domains(domain_key),
  locale            TEXT NOT NULL,
  io_type           TEXT NOT NULL CHECK (io_type IN ('input','output','both')),
  category          TEXT NOT NULL,
  sub_category      TEXT,
  severity          TEXT NOT NULL CHECK (severity IN ('low','medium','high','critical')),
  priority          INT  NOT NULL DEFAULT 100,
  action            TEXT NOT NULL,
  pattern_bundle    JSONB NOT NULL DEFAULT '{}'::jsonb,
  message_template  JSONB NOT NULL DEFAULT '{}'::jsonb,
  regulation_tags   TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
  examples_positive TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
  examples_negative TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
  enabled           BOOLEAN NOT NULL DEFAULT TRUE,
  version           TEXT NOT NULL DEFAULT '1.0.0',
  source            TEXT NOT NULL DEFAULT 'admin'
                     CHECK (source IN ('file','admin','csv')),
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_rules_domain_locale_io ON rules(domain, locale, io_type) WHERE enabled;
-- Add source column on existing deployments missing it.
ALTER TABLE rules ADD COLUMN IF NOT EXISTS source TEXT NOT NULL DEFAULT 'admin';
```

**분석 / Analysis (Level 2)**

- `rule_id TEXT PRIMARY KEY` — Policy Engine 에서 사람이 읽을 수 있는 ID (`PRIV_KR_001`, …)를 직접 PK 로. `gen-rules.py:emit_rules` 가 `{id_prefix}_{global_idx:03d}` 형태로 생성.
- `domain` FK → `domains(domain_key)`. JSON 번들의 `domain` 값이 *반드시 도메인 테이블에 존재*해야 INSERT 성공.
- `io_type CHECK ('input','output','both')`, `severity CHECK ('low','medium','high','critical')` — `gen-rules.py:40` 의 `SEVERITY` 상수와 *동일 enum*. 양쪽 동기화 필수.
- `action TEXT` 는 *CHECK 미지정* — `gen-rules.py:41-45` 의 12개 ACTIONS enum 강제가 *DB 단계에서는 안 됨*. 비표준 액션이 슬립하면 DB 가 받아들이고 Policy Engine 측 코드 실행 시점에서 폭발할 수 있음.
- `pattern_bundle JSONB` — 정규식·classifier 설정 묶음. JSONB 라 `?` / `@>` 연산자로 빠른 조회.
- 인덱스 `idx_rules_domain_locale_io ... WHERE enabled` — **partial index**. `enabled=true` 인 룰만 색인 → 폐기된 룰이 많아지면 인덱스 크기 절약.
- `ALTER TABLE rules ADD COLUMN IF NOT EXISTS source ...` — *방금* CREATE 한 테이블에 같은 컬럼을 다시 추가. **목적: 과거 배포본에는 `source` 컬럼이 없으므로 마이그레이션**. 신규 배포는 무해(중복 무시).

**짚어볼 점 / Watch-outs**

- `action` CHECK enum 부재 — 데이터 무결성 *마지막 게이트*가 DB 가 아닌 서비스 코드가 됨. 향후 권고: `CHECK (action IN ('allow','warn','redact', ...))` 추가.
- `created_at`/`updated_at` 모두 default `now()` — `updated_at`은 *수정 시 자동 갱신 트리거*가 없음. ORM/서비스 코드가 명시적으로 `now()` 를 박아야 정확.
- 핫패치 ALTER 라인이 *최초 DDL 직후*에 위치 — *왜 그렇게 되었는지* 주석으로 설명되어 있지만, idempotent migration을 init.sql 안에 누적해 가는 것은 향후 stack-up 위험. 정식 마이그레이션 도구(예: `node-pg-migrate`, `flyway`, `sqitch`)로 분리 권장.

### Block 3 — policy_versions / whitelists / decision_events / api_keys / test_cases (라인 51–112)

```sql path=scripts/init-db.sql lines=51-112
CREATE TABLE IF NOT EXISTS policy_versions (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  domain      TEXT NOT NULL,
  version     TEXT NOT NULL,
  bundle      JSONB NOT NULL,
  status      TEXT NOT NULL CHECK (status IN ('draft','staged','active','archived')) DEFAULT 'active',
  created_by  UUID,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (domain, version)
);

CREATE TABLE IF NOT EXISTS whitelists (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  domain            TEXT NOT NULL,
  locale            TEXT NOT NULL,
  category          TEXT NOT NULL,
  patterns          TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
  description       TEXT,
  score_adjustment  NUMERIC NOT NULL DEFAULT -0.1
);

CREATE TABLE IF NOT EXISTS decision_events (
  decision_id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       UUID,
  session_id      TEXT,
  domain          TEXT NOT NULL,
  locale          TEXT NOT NULL,
  io_type         TEXT NOT NULL,
  text_hash       TEXT NOT NULL,
  text_encrypted  BYTEA,
  decision        TEXT NOT NULL,
  risk_score      NUMERIC NOT NULL DEFAULT 0,
  matched_rules   TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
  categories      TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
  policy_version  TEXT,
  latency_ms      INT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_audit_tenant_time ON decision_events(tenant_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_domain_time ON decision_events(domain, created_at DESC);

CREATE TABLE IF NOT EXISTS api_keys (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       UUID REFERENCES tenants(id),
  key_hash        TEXT NOT NULL UNIQUE,
  scopes          TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
  allowed_domains TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
  expires_at      TIMESTAMPTZ,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS test_cases (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  domain            TEXT NOT NULL,
  locale            TEXT NOT NULL,
  io_type           TEXT NOT NULL,
  input_text        TEXT NOT NULL,
  expected_decision TEXT NOT NULL,
  expected_rule_ids TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
  tags              TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

**분석 / Analysis (Level 2)**

- `policy_versions` — 정책 번들의 *버전 관리* 테이블. `UNIQUE(domain, version)` 으로 동일 (도메인, 버전) 중복 방지.
- `whitelists.score_adjustment NUMERIC DEFAULT -0.1` — 화이트리스트 매칭 시 risk score 감산. *왜 -0.1?* 매직 넘버. PRD 에 근거 있을 가능성이 크나 본 파일에는 주석 없음.
- `decision_events` — 모든 결정의 감사 로그. **PII가 직접 저장되지 않도록 `text_hash` + `text_encrypted`(BYTEA) 두 컬럼 분리**. *왜:* 해시는 동일성 검사용, 암호 본문은 권한자만 복호화. 이는 GDPR/PIPA 의 *PII 최소화* 원칙을 따른 설계.
- `idx_audit_tenant_time`, `idx_audit_domain_time` — *시간 역순* 정렬을 위한 인덱스. 감사 대시보드의 “최근 N건 by tenant/domain” 쿼리가 핫패스.
- `api_keys.key_hash UNIQUE` — *해시* 저장 (raw key 가 아님). 키 분실 시 *원본 발급자만* 알고, DB 유출 시에도 추가 보호.
- `test_cases` — 정책 회귀 검증용 시드. `expected_decision`, `expected_rule_ids` 로 *룰 변경 시 자동 검증* 데이터 보관.

**짚어볼 점 / Watch-outs**

- `decision_events.tenant_id UUID` 가 *FK 없음* — 의도적 디커플링 (감사 로그가 tenants 행 삭제로 깨지지 않게) vs 누락? 명시 주석이 없어 모호.
- `whitelists.score_adjustment` 의 매직 넘버 −0.1 — 변경 시 영향 범위 추적 어려움. 권고: 룰 측 메타데이터에 `score_adjustment` 를 두거나 PRD 링크 주석.
- `policy_versions.bundle JSONB` — 매우 큰 페이로드(Phase 1 약 250 KB)가 *행 단위*로 들어감. TOAST 자동 압축은 동작하나, 쿼리 시 *전체 bundle column*을 SELECT 하지 않도록 주의.

### Block 4 — Admin 서비스 테이블 (라인 114–161)

```sql path=scripts/init-db.sql lines=114-161
-- =====================================================================
-- Admin Service tables (opt-in deployment via docker-compose.admin.yml).
-- =====================================================================

CREATE TABLE IF NOT EXISTS admin_users (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email         TEXT NOT NULL UNIQUE,
  password_hash TEXT NOT NULL,
  totp_secret   TEXT,
  totp_enabled  BOOLEAN NOT NULL DEFAULT FALSE,
  role          TEXT NOT NULL DEFAULT 'admin'
                 CHECK (role IN ('admin','super_admin','viewer')),
  status        TEXT NOT NULL DEFAULT 'active'
                 CHECK (status IN ('active','disabled')),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_login_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS admin_login_history (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    UUID REFERENCES admin_users(id) ON DELETE SET NULL,
  email      TEXT NOT NULL,
  ip         TEXT,
  user_agent TEXT,
  success    BOOLEAN NOT NULL,
  reason     TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_admin_login_user_time
  ON admin_login_history(user_id, created_at DESC);

CREATE TABLE IF NOT EXISTS admin_audit_log (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_id    UUID REFERENCES admin_users(id) ON DELETE SET NULL,
  actor_email TEXT,
  action      TEXT NOT NULL,
  target_type TEXT,
  target_id   TEXT,
  payload     JSONB,
  ip          TEXT,
  user_agent  TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_admin_audit_actor_time
  ON admin_audit_log(actor_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_admin_audit_action_time
  ON admin_audit_log(action, created_at DESC);
```

**분석 / Analysis (Level 2)**

- `admin_users.password_hash` — 평문 패스워드 X. bcrypt 해시 가정 (`.env`의 `ADMIN_BCRYPT_ROUNDS`).
- `totp_secret TEXT` — TOTP 시드. 평문 저장 가능성이 높아 보임 — *DB 유출 시 즉시 2FA 우회 위험*. 권고: 별도 KMS 암호화 또는 derived secret.
- `role CHECK (admin / super_admin / viewer)`, `status CHECK (active/disabled)` — DB 단계 enum 강제.
- `admin_login_history` — 로그인 시도 *전부* 기록 (success 컬럼). 실패 사유 (`reason TEXT`) 저장 → brute-force 추적용.
- `admin_audit_log.payload JSONB` — 액션의 *상세 파라미터*. 민감 값(예: 재설정한 비밀번호 해시)이 들어가지 않도록 *서비스 측 책임*.
- `ON DELETE SET NULL` — admin 계정 삭제 시 *기록은 보존* (audit 무결성).

**짚어볼 점 / Watch-outs**

- `totp_secret TEXT` — 평문 저장 위험. 별도 *추가 암호화 계층* 미정. 보안 리뷰 필요.
- `admin_audit_log` 에 `payload JSONB` 가 자유 — *비밀번호 새 값* 같은 민감 데이터가 흘러들지 않도록 *서비스 측 sanitize*가 contract. 본 파일에선 보장 없음.
- `ip TEXT` — `INET` 타입을 쓰면 인덱스/검색 효율 ↑. 향후 개선 여지.

### Block 5 — global 도메인 seed (라인 163–172)

```sql path=scripts/init-db.sql lines=163-172
-- Seed the always-on `global` domain. Sub-domains are seeded by Policy Engine at boot
-- by reading <POLICY_DIR>/<domain>/<category>/<io>.<locale>.json bundles.
INSERT INTO domains (domain_key, display_name, description, regulation_tags, inherits_from)
VALUES (
  'global',
  '{"ko-KR":"공통(전역)","en":"Global"}'::jsonb,
  'Domain-agnostic privacy and safety baseline applied to every request.',
  ARRAY['KR_PIPA','EU_GDPR','US_CCPA','JP_APPI'],
  ARRAY[]::TEXT[]
)
ON CONFLICT (domain_key) DO NOTHING;
```

**분석 / Analysis (Level 2)**

- `ON CONFLICT (domain_key) DO NOTHING` — 멱등성. 동일 SQL 다시 실행해도 안전. 단, `init-db.sql` 은 *first boot only* 실행이라 사실상 한 번만 동작.
- `regulation_tags ARRAY['KR_PIPA','EU_GDPR','US_CCPA','JP_APPI']` — global 도메인이 적용 받는 기본 규제. JSON 번들의 룰별 `regulationTags` 와는 별도 — *도메인 메타*.
- `inherits_from ARRAY[]::TEXT[]` — global 은 상속 부모 없음. 향후 도메인이 `inherits_from = ARRAY['global']` 로 상속받는 구조 암시.

**짚어볼 점 / Watch-outs**

- 추가 도메인(`manufacturing-food` 등)은 *Policy Engine 코드*가 JSON 번들 적재 시 자동 INSERT — 그 로직이 형제 디렉토리에 있고, 본 init.sql 만 보고는 *언제·어떻게* 추가되는지 추적 불가. 운영자가 “domain 행이 왜 없지?” 라고 의심할 때 형제 코드 확인이 필수.

## 파일 수준 평가 / File-Level Verdict

- 강점 / Strengths:
  1. 데이터 무결성을 **CHECK + UNIQUE + FK** 로 적극적으로 DB 단계에서 강제.
  2. *PII 최소화* 설계가 명확 — `text_hash` + `text_encrypted` 분리, `password_hash` 등.
  3. *partial index* (`WHERE enabled`) 같은 Postgres 고급 기능 활용으로 핫패스 비용 최소화.
- 위험 / Risks:
  1. `rules.action` CHECK enum 부재 → 비표준 액션이 DB에 통과 가능.
  2. `totp_secret` 평문 저장 — 보안 리스크.
  3. `ALTER TABLE` 핫패치가 init.sql 안에 — migration 도구 부재의 흔적, 누적 시 사고 위험.
- 개선 권고 / Recommendations (impact 순):
  1. `rules.action CHECK (action IN ('allow','warn','redact','sanitize','block','block_or_redact','block_or_pseudonymize','aggregate_only','refuse','escalate','add_disclaimer','route'))` 추가.
  2. `totp_secret` 를 별도 KMS/wrap 처리 또는 derived secret 으로 분리.
  3. 정식 마이그레이션 도구 도입, init.sql 은 *최초 스키마*로 고정.
- 재읽기 권고 레벨: **3** — 데이터 모델 결정의 *배경*까지 의식하려면 시니어 시점 재읽기.
