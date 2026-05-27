# docker-compose.food.yml — 코드 리뷰 / Code Review

> 리뷰 레벨 / Review Level: 2
> [← INDEX.md](INDEX.md)

## 파일 요약 / File Summary

- 역할 / Role: Phase 2 overlay (manufacturing-food). STUB 단계 — 실제 처리 로직은 형제 서비스 도착 시 자동 활성화.
- 진입점에서의 거리: **1** (privacy + food 결합 시).
- 라인 수: 28.
- 주요 export: `GUARDRAILS_ENABLED_DOMAINS` 를 `global,manufacturing-food` 로 확장 + mf-food JSON 마운트.
- 의존 모듈: `docker-compose.yml`, `docker-compose.privacy.yml` (관용 사용), `scripts/manufacturing-food.{kr,en}.json`.

## 라인 단위 분석 / Line-by-Line Analysis

```yaml path=docker-compose.food.yml lines=1-29
# Phase 2 (STUB — not yet implemented) — Manufacturing.Food domain bundle.
# Combine with privacy:
#   docker compose -f docker-compose.yml \
#                  -f docker-compose.privacy.yml \
#                  -f docker-compose.food.yml up -d
#
# When phase 2 ships, drop the actual bundles into
#   <Policy-Engine>/policies/manufacturing-food/{privacy,compliance,safety,ip}/...json
# and the loader will pick them up at boot. The overlay only flips the
# enabled-domains list; no service changes required.

services:
  policy-engine:
    environment:
      GUARDRAILS_ENABLED_DOMAINS: "global,manufacturing-food"
    volumes:
      # Phase 2 seed (127 ko-KR + 127 en rules). Same seed-on-first-boot
      # semantics as Phase 1 — see docker-compose.privacy.yml.
      - ./scripts/manufacturing-food.kr.json:/app/policies/manufacturing-food/manufacturing-food.kr.json:ro
      - ./scripts/manufacturing-food.en.json:/app/policies/manufacturing-food/manufacturing-food.en.json:ro

  detection-engine:
    environment:
      GUARDRAILS_ENABLED_DOMAINS: "global,manufacturing-food"

  mcp-server:
    environment:
      GUARDRAILS_ENABLED_DOMAINS: "global,manufacturing-food"
```

**분석 / Analysis (Level 2)**

- `GUARDRAILS_ENABLED_DOMAINS: "global,manufacturing-food"` — privacy 의 `"global"` 을 **완전히 덮어쓰는** CSV. compose는 *동일 키 머지* 시 *마지막 overlay 가 승리*.
- volumes — `manufacturing-food` 도메인 디렉토리에 JSON 파일을 read-only 마운트. 부팅 시 Policy Engine의 동일 적재 경로(`loadPoliciesFromDir`).
- 주석 line 1 의 *"STUB — not yet implemented"* — 룰 데이터(JSON)는 이미 존재하지만 *서비스 측 응답 로직* 이 phase 2 에 맞춰지지 않았음을 명시. 운영자가 phase 2 를 켜도 룰 검출은 *데이터 적재 단계*에서 끝.

**짚어볼 점 / Watch-outs**

- **CSV 덮어쓰기**: phase 2 overlay 가 phase 1 overlay 의 env 를 그대로 *덮어쓴다*. 만약 향후 phase 3 가 추가될 때 `"global,manufacturing-food,phase3"` 처럼 *전체 누적 리스트*를 다시 적어야 함. 누락 시 silent drop.
- 주석 내 `(127 ko-KR + 127 en rules)` — `gen-rules.py` 의 mf-food 룰 카운트와 *수동 동기화*. 카운트 변경 시 주석 갱신 필수 (자동 검증 없음).
- 컨테이너 안 마운트 경로가 `/app/policies/manufacturing-food/manufacturing-food.kr.json` — *파일 이름이 디렉토리 이름과 중복*. 가독성 OK이지만 형제 코드가 정규식으로 파일 패턴을 잡을 때 유의.

## 파일 수준 평가 / File-Level Verdict

- 강점 / Strengths:
  1. STUB 상태가 *주석으로 명시* — 운영자 혼동 방지.
  2. phase 1 패턴을 그대로 모방 — 동질성.
- 위험 / Risks:
  1. CSV 누적 형식 부재 (phase 3 추가 시 누락 위험).
  2. 룰 카운트 주석 stale 가능.
- 개선 권고 / Recommendations:
  1. *CSV 머지 helper* (예: `GUARDRAILS_ENABLED_DOMAINS_EXTRA`) 도입 — 각 phase 가 *append* 형식으로.
  2. 카운트 주석 제거 또는 `gen-rules.py` 출력 통계에서 자동 인용.
- 재읽기 권고 레벨: **2**.
