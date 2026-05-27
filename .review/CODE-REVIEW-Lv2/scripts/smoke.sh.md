# scripts/smoke.sh — 코드 리뷰 / Code Review

> 리뷰 레벨 / Review Level: 2
> [← INDEX.md](../INDEX.md)

## 파일 요약 / File Summary

- 역할 / Role: MCP HTTP 엔드포인트의 *4-step* 스모크. health → RRN block → SSN block → benign allow → CC redact.
- 진입점에서의 거리 / Distance from entrypoint: **0** (`make smoke` → 이 파일).
- 라인 수 / LOC: 38.
- 주요 export / Exports: `say` 헬퍼 함수.
- 의존 모듈 / Depends on (internal): MCP Server 의 `GET /health` + `POST /mcp/tools/validate_input` + `POST /mcp/tools/validate_output` 엔드포인트.
- 사용된 외부 패키지 / External: `bash`, `curl`, `jq`.
- 부수효과 / Side effects: 외부 HTTP 호출, stdout.
- 동시성 모델: 없음 (순차).
- 테스트 커버리지 흔적: 없음.

## 라인 단위 분석 / Line-by-Line Analysis

```bash path=scripts/smoke.sh lines=1-8
#!/usr/bin/env bash
set -euo pipefail

MCP_URL="${MCP_URL:-http://localhost:8080}"
API_KEY="${GUARDRAILS_API_KEY:-dev-key-please-change}"

say() { printf "\n\033[1;36m== %s ==\033[0m\n" "$1"; }
```

**분석 / Analysis (Level 2)**

- `#!/usr/bin/env bash` — `bash` 인터프리터를 `PATH` 에서 검색. macOS의 구식 `/bin/bash` 와 brew bash 양쪽 호환.
- `set -euo pipefail` — 세 안전 옵션:
  - `-e`: 명령 실패 즉시 종료
  - `-u`: 미정의 변수 참조 시 종료 (`$UNSET` 사용 차단)
  - `-o pipefail`: 파이프 마지막 명령 뿐 아니라 *중간* 명령 실패도 전체 실패로 인식. `curl … | jq` 에서 `curl` 실패가 가려지지 않게.
- `MCP_URL="${MCP_URL:-…}"` — bash parameter expansion. `MCP_URL`이 unset/empty 면 기본값. `set -u` 와 결합해도 안전한 형태.
- `API_KEY` default = `dev-key-please-change` — `.env.example`의 `GUARDRAILS_API_KEY` 와 동일. 로컬·CI 어디서나 동작하도록 한 *대신* 운영 stack에 실수로 실행해도 인증이 통과될 수 있음 → Risk Hotspot.
- `say` — ANSI cyan + bold(`\033[1;36m`) 구분자. 출력의 가독성을 위한 단순 헬퍼.

**짚어볼 점 / Watch-outs**

- `set -e` + 함수: bash의 `-e`가 함수 내부에서는 *함수의 종료 코드*만 보지 *내부 명령*은 보지 않을 수 있는 미묘한 케이스 존재. 본 스크립트는 함수가 단일 `printf` 한 줄이라 안전.
- ANSI escape — 비-tty 출력(파이프, CI 콘솔)에서 *제어문자가 그대로 보임*. `[[ -t 1 ]]` 가드 미적용. CI 로그가 지저분해질 수 있음.

```bash path=scripts/smoke.sh lines=9-39
say "health_check"
curl -fsS "$MCP_URL/health" | jq .

say "validate_input — Korean RRN should BLOCK"
curl -fsS -X POST "$MCP_URL/mcp/tools/validate_input" \
  -H "Content-Type: application/json" \
  -H "x-api-key: $API_KEY" \
  -d '{"text":"제 주민등록번호는 900101-1234567 입니다.","domain":"global","locale":"ko-KR"}' \
  | jq .

say "validate_input — US SSN should BLOCK"
curl -fsS -X POST "$MCP_URL/mcp/tools/validate_input" \
  -H "Content-Type: application/json" \
  -H "x-api-key: $API_KEY" \
  -d '{"text":"My SSN is 123-45-6789.","domain":"global","locale":"en"}' \
  | jq .

say "validate_input — benign sentence should ALLOW"
curl -fsS -X POST "$MCP_URL/mcp/tools/validate_input" \
  -H "Content-Type: application/json" \
  -H "x-api-key: $API_KEY" \
  -d '{"text":"오늘 회의는 오후 3시에 있습니다.","domain":"global","locale":"ko-KR"}' \
  | jq .

say "validate_output — leaking credit card should REDACT"
curl -fsS -X POST "$MCP_URL/mcp/tools/validate_output" \
  -H "Content-Type: application/json" \
  -H "x-api-key: $API_KEY" \
  -d '{"text":"Customer card: 4111 1111 1111 1111","domain":"global","locale":"en"}' \
  | jq .
```

**분석 / Analysis (Level 2)**

- `curl -fsS` 플래그:
  - `-f` (fail): HTTP ≥ 400이면 0이 아닌 종료 코드. `set -e` 와 결합해 스모크가 *자동 실패*.
  - `-s` (silent): 진행률 출력 제거.
  - `-S` (show-error): 그래도 에러 메시지는 보임.
- `| jq .` — JSON pretty. `jq` 미설치 시 *스모크 자체 실패* (Makefile의 `smoke-admin` 처럼 `2>/dev/null || cat` fallback 없음).
- 헤더 두 개: `Content-Type: application/json`, `x-api-key: $API_KEY`. 본 변수가 unset이면 `set -u`로 인해 *스크립트 시작 시점에* 실패하므로 이 라인은 안전.
- `-d` payload — *시각적 검증*만 가능한 단일 inline JSON. 따옴표 escape 없음 — Bash single quote 안에 JSON 더블 quote 사용. 한국어 텍스트도 직접 들어감 (UTF-8).
- 4개 시나리오 페어: RRN/SSN/benign/CC. *기대 동작이 주석에 박혀있음* (`should BLOCK`, `should ALLOW`, `should REDACT`).

**짚어볼 점 / Watch-outs**

- **어서션 부재**: 응답이 실제로 `decision=block`인지 *검증하지 않는다*. HTTP 200 이면 성공으로 친다. PR을 통해 정책이 깨져도 스모크가 *조용히 통과*할 수 있음. 권고: `curl -fsS ... | jq -e 'select(.decision == "block")'` 식으로 `jq -e` 가드.
- API 키가 *유효한 토큰*이라는 보장 없음. `GUARDRAILS_API_KEY` 가 stack의 *환경*과 다르면 401/403 → `-f`로 즉시 실패하므로 적어도 *침묵 실패*는 없음.
- benign 시나리오의 텍스트(`"오늘 회의는 오후 3시에 있습니다."`)에 *3시*라는 단순 숫자가 들어가 있어 향후 룰이 추가될 때 false positive 위험 — 시나리오 텍스트도 *룰 회귀 면역*해야 한다는 관점에서 짚어둘 만함.
- `validate_output` 호출 시 `4111 1111 1111 1111` 카드 번호 — 표준 Visa test BIN. Luhn 통과. 룰 측에서 “테스트 카드 BIN 화이트리스트”를 끄지 않았다면 정확히 redact 발생.

## 파일 수준 평가 / File-Level Verdict

- 강점 / Strengths:
  1. *4가지 핵심 경로* (input block × 2, allow, output redact)를 한 번에 점검.
  2. `set -euo pipefail` + `-fsS` 로 *조용한 실패*가 최소화.
- 위험 / Risks:
  1. **응답 본문 어서션 없음** → 룰 회귀가 잠재화.
  2. API 키 default 의 광역 사용 — 운영 stack에서도 통과 가능.
- 개선 권고 / Recommendations (impact 순):
  1. 응답 본문에 대해 `jq -e` 어서션 추가 (`.decision == "block"` 등).
  2. tty 가드 후 ANSI 색상 조건 적용.
  3. 운영 stack 대상 호출 시 *명시적 confirm* (예: `MCP_URL` 이 prod 도메인이면 “REALLY?”).
- 재읽기 권고 레벨: **2** — 충분.
