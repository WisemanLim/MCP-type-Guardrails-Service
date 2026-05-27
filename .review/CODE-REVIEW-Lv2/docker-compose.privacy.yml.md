# docker-compose.privacy.yml — 코드 리뷰 / Code Review

> 리뷰 레벨 / Review Level: 2
> [← INDEX.md](INDEX.md)

## 파일 요약 / File Summary

- 역할 / Role: Phase 1 overlay — `global` 도메인 활성화 + privacy JSON 번들 마운트.
- 진입점에서의 거리: **1** (base + 본 overlay 결합 시 부팅).
- 라인 수: 26.
- 주요 export: policy-engine·detection-engine·mcp-server 의 `GUARDRAILS_ENABLED_DOMAINS` 갱신, 두 JSON 볼륨 추가.
- 의존 모듈: `docker-compose.yml`(base), `scripts/privacy.{kr,en}.json`(gen-rules.py 산출).
- 사용된 외부 패키지: 없음.
- 부수효과: read-only 파일 마운트, env override.
- 동시성 모델: 해당 없음.
- 테스트 커버리지 흔적: smoke.sh의 RRN/SSN 시나리오가 이 overlay 기준.

## 라인 단위 분석 / Line-by-Line Analysis

```yaml path=docker-compose.privacy.yml lines=1-27
# Phase 1 — Privacy (domain-agnostic).
# Activates the built-in `global/privacy` rule bundle.
# This overlay can be combined with any later domain overlay (food, chemical, etc.).

services:
  policy-engine:
    environment:
      GUARDRAILS_ENABLED_DOMAINS: "global"
    volumes:
      # Mount the canonical generator output as Phase 1 seed data. Files are
      # placed inside the global domain directory so loadPoliciesFromDir
      # picks them up alongside any other bundles that ship in the image.
      # On first boot, PoliciesService.seedIfNeeded() upserts these rules
      # into the rules table (source='file'); subsequent boots see rows
      # already present and leave the DB alone (preserving Admin edits).
      - ./scripts/privacy.kr.json:/app/policies/global/privacy.kr.json:ro
      - ./scripts/privacy.en.json:/app/policies/global/privacy.en.json:ro
      - policy-cache:/app/.cache

  detection-engine:
    environment:
      GUARDRAILS_ENABLED_DOMAINS: "global"

  mcp-server:
    environment:
      GUARDRAILS_ENABLED_DOMAINS: "global"
```

**분석 / Analysis (Level 2)**

- Compose overlay 의 *환경/볼륨 추가* 패턴. 같은 키(`environment`, `volumes`)는 *base 와 머지*되어 새 키가 더해진다(또는 동일 키는 override).
- `GUARDRAILS_ENABLED_DOMAINS: "global"` — base의 `${GUARDRAILS_ENABLED_DOMAINS:-global}` 와 동일 값을 *명시*. *왜:* phase overlay가 곧 *enabled-domains의 단일 진실*이 되도록 — 운영자가 `.env` 만으로 domain을 켜는 것을 막고 phase 파일 선택으로 일관화.
- volumes 두 줄 — *파일 단위* 마운트. `:ro` (read-only) 가 안전 가드. Policy Engine이 *부팅 시 적재*하고 *재기록은 DB로* 한다는 contract.
- `policy-cache:/app/.cache` 는 base 의 동일 볼륨을 *다시 선언* — compose merge 가 동일 volume 항목을 *중복 제거*. 무해.
- `detection-engine` 과 `mcp-server` 는 환경만 갱신, 볼륨 변경 없음. JSON 적재는 *policy-engine 만의 책임*.

**짚어볼 점 / Watch-outs**

- 호스트 경로 `./scripts/privacy.kr.json` 가 *bind mount*. 운영 호스트에서 *파일 삭제/리네임*이 컨테이너에 즉시 반영(부팅 중이라면 mount 실패). 운영 시 *git checkout 가드* 권장.
- `GUARDRAILS_ENABLED_DOMAINS` 가 phase 2 overlay 에서 `"global,manufacturing-food"` 로 덮어쓰일 때 *전체 CSV 재정의*임을 인지(append 아님). 새 phase 추가 시 항상 *누적 리스트*로 작성해야.
- 주석 라인 11–15 가 형제 코드의 함수명(`loadPoliciesFromDir`, `PoliciesService.seedIfNeeded`)을 *문서로 참조* — 형제 코드 리네임 시 주석이 stale. 코드↔주석 양방 sync 부담.

## 파일 수준 평가 / File-Level Verdict

- 강점 / Strengths:
  1. *오버레이 단일 진실*로 도메인 활성화 — phase 선택의 일관성.
  2. read-only 마운트 + 파일 단위 — 보안 좋음.
- 위험 / Risks:
  1. CSV가 *덮어쓰기 형식* — phase 추가 시 누락 가능.
  2. 주석이 형제 코드 함수명에 의존 — sync 부담.
- 개선 권고 / Recommendations:
  1. CSV 누적 패턴을 *helper script* 또는 *기본 env + overlay env list 머지* 로 정형화.
  2. 형제 코드 함수명 대신 *추상적 동작* 으로 주석.
- 재읽기 권고 레벨: **2**.
