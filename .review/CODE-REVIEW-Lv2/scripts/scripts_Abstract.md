# scripts/ — 디렉토리 개요 / Directory Abstract

> [← INDEX.md](../INDEX.md)

## 파일 목록 / File List

| 파일 / File | LOC | 역할 / Role | 리뷰 링크 / Review |
|---|---|---|---|
| gen-rules.py | 4539 | 정책 룰 데이터 → 4개 JSON 번들 생성기 (`privacy.{kr,en}.json`, `manufacturing-food.{kr,en}.json`) | [gen-rules.py.md](gen-rules.py.md) |
| init-db.sql | 172 | Postgres 초기 스키마 (rules, decision_events, api_keys, admin_users 등 11 tables) | [init-db.sql.md](init-db.sql.md) |
| smoke.sh | 38 | MCP HTTP 스모크 4-step | [smoke.sh.md](smoke.sh.md) |
| privacy.kr.json | 7146 | gen-rules.py 산출물 — Phase 1 ko-KR (데이터, 리뷰 미선택) |  |
| privacy.en.json | 7146 | 동일 — Phase 1 en |  |
| manufacturing-food.kr.json | 3656 | 동일 — Phase 2 ko-KR |  |
| manufacturing-food.en.json | 3656 | 동일 — Phase 2 en |  |

## 디렉토리 구조 요약 / Structure Summary

이 디렉토리는 **시드 데이터와 부팅 시 컨테이너로 마운트되는 리소스의 단일 소스**이다.

- `init-db.sql` 은 Postgres 컨테이너의 `docker-entrypoint-initdb.d`에 read-only로 마운트되어 *첫 부팅에만* 실행된다.
- `*.json` 4개는 `docker-compose.privacy.yml` / `docker-compose.food.yml` 의 volume 블록을 통해 Policy Engine 컨테이너의 `/app/policies/<domain>/...` 경로에 read-only로 마운트된다. Policy Engine은 부팅 시 이 파일들을 읽어 rules 테이블이 비어 있으면 bulk insert (`source='file'`) — *그 코드는 형제 디렉토리*에 있고, 본 루트는 그 인터페이스만 보장한다.
- `gen-rules.py` 는 *위 4개 JSON 의 생성기*. 결정적·idempotent — `generatedAt` 만 빼면 byte-stable.
- `smoke.sh` 는 운영자가 `make smoke` 로 호출하는 *외부* 스모크. 본 디렉토리 안의 다른 파일에 의존하지 않음.

## 주요 의존 관계 / Key Dependencies

- **out → compose mount**: `gen-rules.py` 출력 JSON 4종이 `docker-compose.privacy.yml:16-17` / `docker-compose.food.yml:19-20` 의 volume 항목으로 직접 참조됨. 파일 이름 변경 시 양쪽을 동시에 수정해야 한다.
- **in ← schema 합의**: `gen-rules.py:RuleSpec.to_dict()` 의 필드명(`ruleId`, `domain`, `locale`, …)이 Policy Engine의 GuardrailRule schema와 *키 이름·enum 값까지 일치*해야 한다 (`SEVERITY`, `ACTIONS` 상수 참조).
- **DDL ↔ schema**: `init-db.sql:25-46` 의 `rules` 테이블 컬럼이 JSON 번들의 필드와 1:1 매핑된다 (snake_case ↔ camelCase 변환은 Policy Engine 측 책임).

## 위험 신호 / Risk Signals

- **데이터 정의에 enum 외 액션이 자유롭게 섞임** (`block_or_summarize`, `add_compliance_notice`, `advise_pseudonymization` 등). `gen-rules.py`의 `non_std_map`이 후처리로 흡수하지만, *조용한 매핑*이라 오타 시 원본 그대로 출력되어 schema 검증을 실패시킬 수 있음. 자세한 사례는 [gen-rules.py.md](gen-rules.py.md) Step 5 분석 참조.
- **OTP 룰의 정규식 `\b\d{6}\b`** ([gen-rules.py:1003](../../scripts/gen-rules.py#L1003)) — false positive 우려: 일반 6자리 수(연도, 우편번호 일부, 가격 등)와 충돌. Policy Engine 측 컨텍스트 필터에 의존.
- **SQL DDL의 hot-patch 라인** (`init-db.sql:49` `ALTER TABLE … ADD COLUMN IF NOT EXISTS source`) — `CREATE TABLE` 바로 다음에 동일 컬럼을 다시 추가. *과거 배포본을 위한 마이그레이션을 init.sql 안에 적은 자국*. 향후 정식 마이그레이션 도구로 이전 권장.
