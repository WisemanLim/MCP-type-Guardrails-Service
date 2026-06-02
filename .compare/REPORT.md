# 비교분석 REPORT: MCP-type-Guardrails-Service

## 1. 개요

| 항목 | 내용 |
|---|---|
| 비교 일자 | 2026-06-02 |
| 기준(ref, 개선·신규) | `DocuGuard-AI-ops` (오케스트레이션 루트) + `DocuGuard-AI-Database` (분리된 DB 프로젝트) |
| 적용 대상(current) | `MCP-type-Guardrails-Service` (현행 오케스트레이션 루트, DB 자산 인라인 보유) |
| 적용 원칙 | 추가적·명백한 개선만 이식. 현행 식별자/네이밍(`Guardrails-Service-*`, 컨테이너 `gr-*`, DB `guardrails`)은 보존. 리네이밍(`DocuGuard-AI-*`, `dg-*`, `docuguard`)은 이식하지 않음. 동작 변경/구조 재편은 보류. |

### 핵심 판단

ref 두 프로젝트는 current 와 **동일 시스템의 리네이밍 + 구조 재편 버전**이다. 차이는 크게 세 부류:

1. **리네이밍** (`DocuGuard-AI-*` / `dg-*` / `docuguard`) — 개선이 아니라 브랜딩 변경. **이식 안 함.**
2. **오케스트레이션 아키텍처 재편** — ref 는 tier별 compose 파일(server/admin/policy/detection/database) + `PHASE=도메인-ENV 주입` 모델. current 는 phase+suffix 오버레이(admin 중심) 모델. 둘 다 유효한 설계이며 전면 교체는 고위험. **보류.**
3. **DB 자산·시드 적재 도구·문서** — ref `DocuGuard-AI-Database` 가 가진 `load-seeds.py`, 시드 적재 Makefile 타깃, `INGEST-GUIDE.md` 는 current 에 **없는 명백한 추가 가치**. **이식함(현행 네이밍/경로/도메인 모델에 맞게 적응).**

---

## 2. 구조 비교

### 2.1 디렉토리/파일 인벤토리

| 자산 | ref ops | ref Database | current | 비고 |
|---|---|---|---|---|
| `Makefile` | 있음(tier+PHASE-ENV) | 있음(seed 적재) | 있음(phase+suffix) | 설계 상이 |
| `docker-compose.yml` | network-only 베이스 | standalone DB 2서비스 | 5서비스 풀스택 베이스 | current 가 베이스에 전 서비스 포함 |
| tier별 compose | `*.{database,policy,detection,server,admin}.yml` | — | 없음(오버레이는 phase/suffix) | ref 만 tier 분리 |
| phase/도메인 오버레이 | 없음(ENV 주입) | — | `*.{privacy,food}.yml` | 모델 상이 |
| admin 오버레이 | `admin.yml`, `local-admin.yml` | — | `admin.yml`, `admin-web.yml`, `admin-local.yml`, `admin-standalone.yml` | current 가 더 다양 |
| local(SQLite) 오버레이 | `local-policy.yml`, `local-admin.yml` | — | `local.yml`, `admin-local.yml` | 동등 기능 |
| `.env.example` | 있음(REDACT 포함, tier 주석) | — | 있음 | §3 참조 |
| `scripts/smoke.sh` | 포트별 health 점검(7-tier) | — | MCP 기능 테스트(validate_input/output) | **상호보완**, 용도 다름 |
| `scripts/gen-rules.py` | 있음(`domain=privacy`, → seed/) | 있음(동일) | 있음(`domain=global`, → scripts/) | 도메인 모델 차이 |
| `scripts/load-seeds.py` | — | **있음** | **없음 → 이식함** | 신규 |
| 시드 `*.json` | — | seed/ (privacy=privacy) | scripts/ (privacy=global) | 위치·도메인 차이 |
| `init-db.sql` | — | init/ (privacy 도메인 INSERT 포함) | scripts/ (privacy 도메인 INSERT 없음) | §4 참조 |
| `INGEST-GUIDE.md` | — | **있음(27KB)** | **없음 → 이식함** | 신규 |
| `Dockerfile.postgres/redis` | — | 있음(이미지 baked) | 없음(공식 alpine 이미지 사용) | current 는 init-db.sql bind-mount |
| `test/` | deployment-verification.md, build 로그 | — | Phase#1 스크립트 + runs/ 다수 | current 가 더 풍부 |

### 2.2 별도 Database 프로젝트 분리 여부 — 판단

ref 는 DB(Postgres/Redis + 스키마/시드/생성기/적재기)를 `DocuGuard-AI-Database` 독립 프로젝트로 분리하고, ops 는 그 `Dockerfile.postgres/redis` + `seed/` + `init/` 를 build context 로 참조한다.

**current 권고: 현행 인라인 유지.** current 는 공식 `postgres:16-alpine` / `redis:7-alpine` 이미지를 그대로 쓰고 `scripts/init-db.sql` 을 bind-mount 하는 단순 모델이며 정상 동작한다. 별도 DB 프로젝트 분리는 (a) 신규 레포 생성, (b) Dockerfile.postgres/redis 추가, (c) ops compose 의 build context 재배선이 필요한 **구조 결정**이라 이번 적용 범위에서 제외(§6 보류). 다만 ref 가 DB 프로젝트에 둔 **시드 적재 도구·문서**는 레포 분리 없이도 current `scripts/` 에 그대로 이식 가능하므로 이식했다.

---

## 3. 설정/오케스트레이션 변경 (diff 요약)

### 3.1 Makefile

| 구분 | ref(ops) | current | 적용 |
|---|---|---|---|
| 위상 모델 | tier(server/admin/policy/detection/db) 조합 + `PHASE=domains` ENV | phase(p1/p1-p2) × suffix(admin/web/local/...) 오버레이 | 모델 차이 — 교체 안 함 |
| 빌드 강제 옵션 | `COMPOSE_BAKE/DOCKER_BUILDKIT/COMPOSE_DOCKER_CLI_BUILD=0` (콤마 경로 buildx-bake 회피) | 없음 | **보류**(§6 — 잠재적 유용, 동작 영향 검증 필요) |
| seed 적재 타깃 | (Database Makefile) `seed/reseed/seed-sql/seed-verify/reset-rules` | 없음 | **이식함** |
| `psql`/`redis-cli` | 있음 | 이미 있음 | 변경 없음 |
| `config-check`/`phase-check` | 있음(CI 머지검증) | 없음 | 보류(모델 의존적) |

ref Database Makefile 의 seed 적재 타깃 5종을 current Makefile 의 Diagnostics 섹션 뒤에 **추가**했다. 컨테이너/유저/DB 명은 현행값(`postgres` 서비스, `guardrails`)을 사용하고, 적재는 `docker compose exec -T postgres psql` 로 파이프(현행 `psql` 타깃과 동일 패턴). `help` 텍스트에 SEED 섹션을 추가했다.

### 3.2 docker-compose

서비스 정의 자체는 동등(같은 포트 8080–8085, 같은 healthcheck 패턴, 같은 env). 차이는 **네이밍**(ref `docuguard-*`/`dg-*` vs current `gr-*`)과 **파일 분할 방식**뿐. 네이밍은 보존 원칙에 따라 이식하지 않음. compose 파일은 **수정하지 않았다**(현행 동작 보존).

### 3.3 .env.example

| 키 | ref | current | 판단 |
|---|---|---|---|
| `REDACT_SERVICE_URL` / `REDACT_EXPOSED_PORT=8085` | 있음 | 없음 | redact 서비스가 별도 포트로 존재할 때만 의미. current 는 8085 미사용 → **보류**(서비스 실재 확인 필요) |
| `ADMIN_WEB_EXPOSED_PORT=3001` | 있음 | 없음(compose 가 기본값 3001 사용) | 문서화 가치는 있으나 동작엔 무영향 → 보류 |
| `ADMIN_CORS_ORIGINS` | 있음 | 없음(compose 는 참조함) | compose 가 `${ADMIN_CORS_ORIGINS:-}` 로 기본 처리 → 무해, 보류 |
| `POLICY_ENGINE_URL`/`AUDIT_SERVICE_URL`/`DETECTION_ENGINE_URL` | 명시 | 없음(compose 내부 service DNS 사용) | current 는 compose 가 내부 URL 고정 → 불필요 |
| `ADMIN_TOTP_ISSUER` | `DocuGuard-Admin` | `Guardrails-Admin` | 네이밍 — 현행 유지 |

`.env.example` 키 차이는 모두 (a) 네이밍이거나 (b) current compose 가 이미 기본값으로 처리하는 항목이라 **추가 이식 없음**(불필요한 키 주입은 혼란만 유발). §6 에 후보로 기록.

---

## 4. 개선/추가/수정 항목

### A. `scripts/load-seeds.py` (신규 이식)
- **설명**: 의존성 없는(stdlib only) 시드 적재 SQL 생성기. Postgres 에 직접 접속하지 않고 idempotent SQL(`source='file'`, `ON CONFLICT (rule_id) DO NOTHING`, `DbService.bulkInsertRules` 와 동일 컬럼 매핑)을 stdout/파일로 출력. Policy Engine 없이도 `rules` 테이블 적재 가능(DB tier 단독 기동/Policy 미접속 시 복구 경로). 참조 도메인 FK 충족용 `domains` upsert 선행.
- **ref 위치**: `DocuGuard-AI-Database/scripts/load-seeds.py`
- **영향도**: 신규 운영 도구. 기존 동작 불변(별도 호출 시에만 작동).
- **QA 리스크**: 낮음. current `rules` 스키마 17컬럼이 `RULE_COLUMNS` 와 정확히 일치 확인. 실제 current 시드로 생성 검증 완료(744룰: global 490 + manufacturing-food 254, 도메인 upsert 3건 — 모두 현행 init-db.sql 에 선등록되어 FK 위반 없음). 적응: `SEED_DIR=SCRIPT_DIR`(현행은 시드가 `scripts/`), dollar-quote 태그 `$dg$`→`$gr$`, docstring/주석을 현행 경로·도메인 모델로 수정.

### B. Makefile seed 적재 타깃 (신규 이식)
- **설명**: `seed`(적재), `reseed`(file 행 교체·admin 보존), `seed-sql`(SQL만 렌더), `seed-verify`(도메인별 카운트), `reset-rules`(file 행 삭제) 5종.
- **ref 위치**: `DocuGuard-AI-Database/Makefile`
- **영향도**: 추가 타깃만. 기존 타깃 영향 없음(`make -n up-p1` 정상 확인).
- **QA 리스크**: 낮음. `reset-rules`/`reseed` 는 `source='file'` 행만 대상(admin 편집 보존). `make -n` 으로 5종 모두 정상 전개 확인.

### C. `INGEST-GUIDE.md` (신규 이식)
- **설명**: 룰 데이터 수집·스키마·도메인 로드맵 표준 문서(번들 스키마 18필드, category/action enum, ruleId 규칙, ISIC/KSIC 매핑, Phase 1–10 수집 목표, 신규 도메인 추가 절차, 검증 스니펫).
- **ref 위치**: `DocuGuard-AI-Database/INGEST-GUIDE.md`
- **영향도**: 문서. 코드/동작 무영향.
- **QA 리스크**: 낮음(문서 정합성만). 경로(`seed/`→`scripts/`, `init/init-db.sql`→`scripts/init-db.sql`), 네이밍(`DocuGuard-AI`→`Guardrails-Service`) 치환. **현행 도메인 모델 주의 콜아웃 추가**: current 는 privacy 를 `domain=global` 로 적재(leaf 분리 안 함)하므로 §1.1 인벤토리 표와 본문에 "현행 vs 권장 목표" 구분 명시.

### D. privacy leaf 도메인 모델 (수정 — **보류**, §6)
- **설명**: ref 는 privacy 를 `global` 로 체인되는 별도 leaf 도메인(`domain=privacy`)으로 분리, init-db.sql 에 `privacy` 도메인 INSERT 추가, gen-rules.py 가 `domain=privacy` emit. current 는 privacy 를 `global` 에 직접 포함.
- **ref 위치**: `DocuGuard-AI-Database/{init/init-db.sql, scripts/gen-rules.py, seed/*.json}`
- **영향도**: **높음**(데이터 모델·동작 변경).
- **QA 리스크**: 높음. seed `domain` 필드 + init-db.sql 도메인 등록 + **Policy Engine 도메인 리졸버** + `docker-compose.privacy.yml` 마운트 경로(`/app/policies/global/` → `/app/policies/privacy/`)를 **동시에** 바꿔야 함. 멀티 컴포넌트 동작 변경 → 사람 판단 필요.

### E. compose 빌드 강제 ENV (추가 — **보류**, §6)
- **설명**: ref Makefile 의 `COMPOSE_BAKE=false` / `DOCKER_BUILDKIT=0` / `COMPOSE_DOCKER_CLI_BUILD=0` — 빌드 컨텍스트 경로에 콤마가 있을 때 Compose v5 buildx-bake 가 깨지는 문제 회피용. current 의 dev 트리 경로 `DA(Python,R,...)` 에 콤마가 있어 잠재적으로 동일 이슈 가능.
- **QA 리스크**: 중간. 빌드 경로에 영향. current 가 현재 빌드에 문제 없다면 불필요한 부작용(클래식 빌더 강제) 가능 → 실 빌드 환경 확인 후 결정 권장.

---

## 5. 적용 내역 (Applied)

| 파일 | 변경 | 이유 |
|---|---|---|
| `scripts/load-seeds.py` | **신규 생성** | Policy 미경유 시드 적재 도구. current 에 부재한 명백한 운영 가치. 현행 레이아웃(`SEED_DIR=scripts/`)·네이밍·도메인 모델(`global`)에 맞게 적응. 실제 시드로 744룰 생성 검증 완료. |
| `Makefile` | seed 적재 타깃 5종 + help SEED 섹션 **추가** | ref Database Makefile 의 seed/reseed/seed-sql/seed-verify/reset-rules 이식. 현행 컨테이너/유저/DB 명 사용. 기존 타깃 불변. |
| `INGEST-GUIDE.md` | **신규 생성** | 룰 데이터 수집 표준 문서. 경로·네이밍 치환 + 현행 도메인 모델(privacy=global) 주의 콜아웃 추가. |

**삭제한 파일 없음.** 현행 compose 파일·기존 시드·init-db.sql·기존 Makefile 타깃 모두 보존.

---

## 6. 미적용/보류 (Deferred — 사람 판단 필요)

| 항목 | 이유 |
|---|---|
| 리네이밍(`DocuGuard-AI-*`/`dg-*`/`docuguard`) | 개선이 아닌 브랜딩 변경. 보존 원칙에 따라 이식 안 함. |
| tier별 compose + `PHASE=ENV` 오케스트레이션 모델 | current 의 phase+suffix 오버레이 모델과 상충하는 다른 설계. 전면 교체는 고위험. 현행 동작 정상. |
| Database 독립 프로젝트 분리 + `Dockerfile.postgres/redis` | 구조 결정(신규 레포·build context 재배선). current 의 공식 이미지+bind-mount 모델로 충분. |
| privacy leaf 도메인 분리(항목 D) | Policy Engine 리졸버 + compose 마운트 + 시드 도메인 동시 변경 필요한 동작 변경. |
| compose 빌드 강제 ENV(항목 E) | 빌드 경로 부작용 가능. 실 빌드 환경에서 콤마-경로 이슈 발생 시에만 적용 권장. |
| `.env.example` 키(REDACT_*, ADMIN_WEB_EXPOSED_PORT, ADMIN_CORS_ORIGINS 등) | redact 서비스 실재 미확인 / current compose 가 이미 기본값 처리. 불필요 키 주입 회피. |
| `config-check`/`phase-check` Makefile 타깃 | ref tier 모델 의존. current 모델용으로 재작성 시 별도 작업. |
| ref `smoke.sh`(포트별 7-tier health) | current `smoke.sh`(MCP 기능 테스트)와 **용도 상이·상호보완**. 덮어쓰면 기능 테스트 손실 → 통합하려면 별도 스크립트로 추가 권장(미적용). |

---

## 7. 검증 결과

도구 가용성: docker 29.3.0 / docker compose v5.1.3 / GNU Make 3.81 / bash 3.2.57 / python3 3.14 — 전부 사용 가능.

### 7.1 Python (load-seeds.py)
- `python3 -m py_compile scripts/load-seeds.py` → **OK**
- 실제 current 시드로 실행: `python3 scripts/load-seeds.py --out ...` → **744룰 / 3 도메인 생성 성공**
  - `-- domains: manufacturing-food=254, global=490`
  - 도메인 upsert 3건(global, manufacturing[자동 부모], manufacturing-food) — 전부 현행 init-db.sql 에 선등록 → FK 위반 없음.

### 7.2 Makefile (`make -n`)
- `seed` / `reseed` / `seed-sql` / `seed-verify` / `reset-rules` → 5종 모두 정상 전개.
- `help` → SEED 섹션 정상 출력.
- 회귀 확인 `up-p1` → 정상 전개(`docker compose -f docker-compose.yml -f docker-compose.privacy.yml up -d`).

### 7.3 docker compose `config -q`
| 대상 | 결과 |
|---|---|
| `docker-compose.yml`(베이스) | OK |
| `admin-web.yml`, `admin-standalone.yml` | OK |
| 병합 p1 (base+privacy) | OK |
| 병합 p1-p2 (base+privacy+food) | OK |
| 병합 p1-admin-web | OK |
| 병합 p1-admin-local | OK |
| 병합 admin-standalone+web | OK |
| 오버레이 단독(privacy/food/local/admin/admin-local) | FAIL — **설계상 정상** |

> 오버레이 fragment 단독 검증 실패는 의도된 동작이다. 이들은 베이스에 병합되어야만 유효한 부분 오버레이(서비스/네트워크를 베이스에서 상속)이며, Makefile 은 항상 베이스와 병합해 호출한다. ref 도 동일 설계다. **본 작업은 어떤 compose 파일도 수정하지 않았으므로 회귀 아님.**

### 7.4 bash (`bash -n`)
- `scripts/smoke.sh` → **OK** (미변경, 회귀 확인용).

---

## 8. QA 체크리스트 & 회귀테스트 권고

### 8.1 적용분 즉시 점검 (수동)
- [x] `python3 -m py_compile scripts/load-seeds.py`
- [x] `python3 scripts/load-seeds.py --out build/seed-rules.sql` → 744룰 렌더
- [x] `make -n seed reseed seed-sql seed-verify reset-rules`
- [x] 병합 토폴로지 `docker compose config -q` (p1/p1-p2/admin-web/admin-local/standalone)
- [x] `bash -n scripts/smoke.sh`

### 8.2 실 DB 대상 회귀(Docker 기동 후 권고)
1. `make up-p1` → Postgres healthy 대기.
2. `make seed-verify` → Policy 부팅 시드 결과 확인(baseline).
3. `make reset-rules` 후 `make seed` → 744룰 재적재 → `make seed-verify` 로 global/manufacturing-food 카운트 일치 확인.
4. `make reseed` 2회 연속 → idempotent(중복 없음·admin 행 보존) 확인.
5. `make smoke` (MCP 기능) → validate_input(RRN/SSN block), validate_output(card redact) 정상.

### 8.3 회귀 위험 영역
- **시드 적재 vs Policy 자동 시드 중복**: `seed` 는 `ON CONFLICT (rule_id) DO NOTHING` 이라 Policy 가 이미 적재한 rule_id 는 건드리지 않음 → 안전. 단 `reseed`/`reset-rules` 는 `source='file'` 행 삭제하므로 Policy 가 file 소스로 넣은 행도 삭제됨(admin 편집 행은 `source='admin'` 이라 보존). 운영 DB 에서 `reset-rules` 사용 시 주의.
- **build/ 디렉토리**: `seed-sql` 이 `build/seed-rules.sql` 생성. `.gitignore` 에 `build/` 포함 여부 확인 권고(미포함 시 추가).
- **INGEST-GUIDE 도메인 서술**: 현행 모델(privacy=global) 주의 콜아웃 반영 완료. 추후 privacy leaf 분리(항목 D) 시 §1.1·상단 콜아웃 동시 갱신 필요.

### 8.4 후속 권고(선택)
- 항목 E(빌드 강제 ENV): dev 트리 `DA(Python,R,...)` 콤마 경로에서 `make build` 실패 재현되면 ref 의 3개 ENV 적용 검토.
- ref `smoke.sh`(포트별 health)를 `scripts/smoke-health.sh` 등 별도 파일로 추가하면 기능 테스트와 인프라 health 점검을 모두 확보(현 `smoke.sh` 덮어쓰지 말 것).
