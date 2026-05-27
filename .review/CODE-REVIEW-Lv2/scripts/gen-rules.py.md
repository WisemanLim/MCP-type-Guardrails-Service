# scripts/gen-rules.py — 코드 리뷰 / Code Review

> 리뷰 레벨 / Review Level: 2
> [← INDEX.md](../INDEX.md)

## 파일 요약 / File Summary

- 역할 / Role: 정책 룰 데이터(튜플 리스트) → 4개 JSON 번들 출력. `privacy.{kr,en}.json` + `manufacturing-food.{kr,en}.json`.
- 진입점에서의 거리 / Distance from entrypoint: **0** (`python3 scripts/gen-rules.py` 가 진입점).
- 라인 수 / LOC: 4539.
- 주요 export / Exports: `main()`, `emit_rules(...)`, `RuleSpec` 데이터클래스, `_category_for_global/_for_mf_food` 헬퍼, `_GLOBAL_CATEGORY_RULES` / `_MF_FOOD_IP / _COMPLIANCE / _SAFETY` 매핑 집합.
- 의존 모듈 / Depends on (internal): 없음 (단일 파일). 출력은 `scripts/*.json` 으로 떨어져 compose 파일들이 마운트.
- 사용된 외부 패키지 / External: Python 표준 라이브러리만 (`json`, `sys`, `dataclasses`, `datetime`, `pathlib`, `typing`).
- 부수효과 / Side effects: `SCRIPT_DIR` 에 4개 파일 write, stdout 진행 로그.
- 동시성 모델 / Concurrency: 없음 (단일 스레드).
- 테스트 커버리지 흔적 / Test coverage signal: 없음. 회귀 검증은 *생성된 JSON을 사람이 검수* 또는 *Policy Engine 부팅 후 smoke* 에 의존.

> 본 파일은 4539줄로 임계치(`--max-lines-per-file 600`)를 크게 초과합니다. 라인 단위 대신 **논리 블록 단위**로 분석합니다. 룰 데이터 튜플 본체(라인 111–2384, 2386–2828, 2835–3751, 3753–4256)는 *형태가 동일한 데이터*이므로 한 블록당 한 *대표 튜플*만 해부하고 나머지는 *집계 평가*합니다.

---

## Block 1 — 모듈 docstring + 임포트 + 상수 (라인 1–45)

```python path=scripts/gen-rules.py lines=1-45
#!/usr/bin/env python3
"""
Guardrail rule bundle generator.

Emits four JSON bundles aligned with the GuardrailRule schema used by the
Policy Engine:

    scripts/privacy.kr.json              -> domain=global,            locale=ko-KR
    scripts/privacy.en.json              -> domain=global,            locale=en
    scripts/manufacturing-food.kr.json   -> domain=manufacturing-food,locale=ko-KR
    scripts/manufacturing-food.en.json   -> domain=manufacturing-food,locale=en

Each privacy bundle ships >= 200 rules across the privacy categories
defined in PRD §5.4 (IDs/Contact/Financial/Credentials/Health/Location/
Biometrics/Sensitive/Children/Logs/Misc). Manufacturing-food bundles
cover the domain-specific PII/safety/compliance/IP buckets from the
Perplexity research.

Run:
    python3 scripts/gen-rules.py

The generator is deterministic and idempotent. Re-running produces a
byte-stable file modulo `generatedAt`.
"""
from __future__ import annotations

import json
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Iterable

SCRIPT_DIR = Path(__file__).resolve().parent

# --------------------------------------------------------------------------- #
# Schema helpers                                                              #
# --------------------------------------------------------------------------- #

SEVERITY = ("low", "medium", "high", "critical")
ACTIONS = (
    "allow", "warn", "redact", "sanitize", "block",
    "block_or_redact", "block_or_pseudonymize", "aggregate_only",
    "refuse", "escalate", "add_disclaimer", "route",
)
```

**분석 / Analysis (Level 2)**

- shebang `#!/usr/bin/env python3` — `chmod +x` 후 직접 실행 가능. 그러나 본 저장소에서는 항상 `python3 scripts/gen-rules.py` 로 명시 호출.
- 모듈 docstring 이 *contract* 를 명시 — “결정적·idempotent, `generatedAt` 제외 byte-stable”. 이는 *PR 시 diff 가독성*을 보장하는 핵심 약속.
- `from __future__ import annotations` — Python 3.10+ 의 PEP 563 *postponed evaluation*. 타입 힌트를 *문자열로 평가*. `dict | None` 같은 PEP 604 union 도 3.10 미만에서 안전.
- import 7개 — 전부 stdlib. 외부 의존 없음 → 운영 환경에서 *Python 본체만* 있으면 동작.
- `field`, `Callable`, `Iterable` import — *현재 코드에서 사용 안 됨*. dead import. 향후 lint 시 정리 후보.
- `SCRIPT_DIR = Path(__file__).resolve().parent` — *어디서 호출해도* `scripts/` 디렉토리에 출력하도록 절대 경로 고정. CWD 의존 제거.
- `SEVERITY` 튜플과 `ACTIONS` 튜플 — *enum 의 단일 진실*. 그러나 *런타임 검증 미적용*. `emit_rules` 가 `non_std_map` 으로 비표준 액션을 후처리하지만, 매핑 누락된 값을 *그대로 통과시킴*.

**짚어볼 점 / Watch-outs**

- **`SEVERITY`/`ACTIONS` 가 *상수일 뿐* assert 없음** — 데이터 튜플의 severity/action 이 enum 밖이면 *조용히* 출력됨. Risk Hotspot #1.
- `field`/`Callable`/`Iterable` unused — `ruff F401`, `pyflakes` 가 자동 잡을 항목. 정리 권고.

---

## Block 2 — `RuleSpec` 데이터클래스 (라인 47–90)

```python path=scripts/gen-rules.py lines=47-90
@dataclass
class RuleSpec:
    """In-memory rule template prior to JSON emission."""
    rule_id: str
    domain: str
    locale: str
    io_type: str
    category: str
    sub_category: str
    description: str
    pattern_type: str
    severity: str
    priority: int
    action: str
    message: dict
    regulation_tags: list
    examples_positive: list
    examples_negative: list
    patterns: dict | None = None

    def to_dict(self) -> dict:
        out = {
            "ruleId": self.rule_id,
            "domain": self.domain,
            "locale": self.locale,
            "ioType": self.io_type,
            "category": self.category,
            "subCategory": self.sub_category,
            "description": self.description,
            "patternType": self.pattern_type,
            "severity": self.severity,
            "priority": self.priority,
            "action": self.action,
            "messageTemplate": self.message,
            "regulationTags": self.regulation_tags,
            "examplesPositive": self.examples_positive,
            "examplesNegative": self.examples_negative,
            "enabled": True,
            "version": "1.0.0",
        }
        if self.patterns is not None:
            out["patterns"] = self.patterns
        return out
```

**분석 / Analysis (Level 2)**

- `@dataclass` 가 `__init__`, `__repr__`, `__eq__` 자동 생성 — 코드량 절감.
- 필드 이름이 *Python convention*인 snake_case. `to_dict()` 가 *JSON convention*인 camelCase 로 매핑. Policy Engine TypeScript 코드의 GuardrailRule 인터페이스가 camelCase 라는 contract.
- `patterns: dict | None = None` — 옵셔널. None 일 때 `to_dict()` 가 키 자체를 *생략*. *왜:* `patterns` 가 없는 룰(분류기 기반)이 JSON 에서 `"patterns": null` 이 아닌 *키 부재* 형태로 직렬화되어 schema validator 가 깔끔하게 처리.
- `enabled: True` / `version: "1.0.0"` 가 *고정* — 모든 생성 룰이 활성 + v1.0.0. Admin 가 DB 에서 개별 토글 가능 (`init-db.sql`의 `enabled BOOLEAN`).

**짚어볼 점 / Watch-outs**

- `message: dict`, `regulation_tags: list` 등 *generic dict/list* 타입 어노테이션. `dict[str, str]` 처럼 generic 매개변수까지 명시하면 더 안전. 현 코드는 `from __future__ import annotations` 가 있어 미래 변경 부담은 낮음.
- `to_dict()` 가 직접 키-by-키 매핑 — *필드 추가/삭제 시 두 군데 수정 필요* (dataclass 필드 + to_dict). 흔한 실수. 자동화 방안: `dataclasses.asdict()` + 키 변환 함수.
- `enabled: True` 와 `version: "1.0.0"` 가 *생성기 단에서 강제* — Admin이 DB 에서 enabled=false 로 끈 후 *gen-rules.py 재실행으로 seedIfNeeded* 가 호출되면 *true 로 되돌릴 위험*. Policy Engine seedIfNeeded 가 “DB 비어있을 때만 INSERT” 하는 가드를 가진다는 *형제 코드 contract* 에 의존.

---

## Block 3 — `msg()` 헬퍼 (라인 92–98)

```python path=scripts/gen-rules.py lines=92-98
# --------------------------------------------------------------------------- #
# Common message helpers                                                      #
# --------------------------------------------------------------------------- #

def msg(ko: str, en: str) -> dict:
    return {"ko-KR": ko, "en": en}
```

**분석 / Analysis (Level 2)**

- 단순 헬퍼. ko/en 두 로케일 dict 생성. *왜 함수로 분리:* `emit_rules` 가 *locale 별로 다른 dict*를 만드는 게 아니라 *bundle 별로 양 로케일 모두 보존* → 메시지 템플릿은 다국어 통합 객체 그대로 JSON에 들어간다.

**짚어볼 점 / Watch-outs**

- 로케일 키가 `"ko-KR"` 인지 `"ko"` 인지 항상 일치해야 — `.env.example` 의 `GUARDRAILS_LOCALES=ko-KR,en` 와 맞물림. 두 곳 sync.

---

## Block 4 — `PRIVACY_INPUT_RULES` 데이터 본문 (라인 100–2384, 약 90 룰)

대표 튜플 (라인 111–123):

```python path=scripts/gen-rules.py lines=109-124
# Format per entry:
#   (subCategory, severity, action, priority,
#    description_ko, description_en, message_ko, message_en,
#    regulationTags, patterns or None,
#    example_pos_ko, example_neg_ko, example_pos_en, example_neg_en)

PRIVACY_INPUT_RULES: list[tuple] = [
    # ===== Identifiers — 30 rules =====
    ("national_id_kr", "critical", "block", 950,
     "주민등록번호 입력 차단",
     "Block Korean Resident Registration Numbers (RRN) in user input.",
     "주민등록번호는 입력할 수 없습니다.",
     "Korean RRN cannot be entered.",
     ["KR_PIPA"],
     {"regex": [r"\b\d{6}[- ]?\d{7}\b"]},
     "제 주민등록번호는 900101-1234567 입니다.",
     "주민등록번호 제도에 대해 설명해 주세요.",
     "My RRN is 900101-1234567.",
     "Explain how the Korean RRN scheme works."),
    ...
]
```

**분석 / Analysis (Level 2)**

- 14-요소 튜플의 *문서화가 라인 105–109 주석으로* 명시. *왜 dataclass가 아닌 tuple?* — *세로 줄 절약* 목적. 4500줄 데이터에서 dataclass `RuleSpec(...)` 호출이 한 룰당 14줄을 차지하면 가독성 폭증. 튜플 + positional 이 *데이터 시트 같은* 외관 유지.
- 각 룰의 *positive example* 은 룰이 매칭해야 하는 텍스트(`"제 주민등록번호는 900101-1234567 입니다."`), *negative example* 은 *주제 토론은 허용*(`"주민등록번호 제도에 대해 설명해 주세요."`). 즉 *PII 입력*과 *PII 토론* 의 의도 분리 — *false positive 회피* 가 데이터에 박혀있음.
- 정규식 `\b\d{6}[- ]?\d{7}\b` — RRN 6+7 패턴. word boundary `\b`. 문자 클래스 `[- ]?` 가 *하이픈 또는 공백 0~1개* 허용. **체크섬(Luhn-like) 미적용** — 정규식 단계는 *candidate* 만 잡고, 컨텍스트/체크섬은 *형제 Detection Engine*이 보강 가정.
- regulation_tags 가 `["KR_PIPA"]` — 단일 규제. SSN(라인 124-) 은 `["US_HIPAA", "US_CCPA"]` 처럼 복수.
- 행동(action) `"block"` — `ACTIONS` enum 에 존재 → `non_std_map` 통과 안 함.

**짚어볼 점 / Watch-outs**

- 데이터 튜플의 *순서 의존* — `emit_rules` 가 positional unpacking. 한 룰이라도 *컬럼 순서를 틀리면* 조용히 잘못 매핑. 헤더 주석이 일치하지 않는 룰이 섞이면 검출이 매우 어렵다.
- 비-enum 액션이 데이터에 자유롭게 등장 (`advise_pseudonymization` (라인 267), `add_compliance_notice` (라인 334), `block_or_summarize` (라인 323), `block_or_generalize` (라인 511), `block_or_route` (라인 223) 등). `non_std_map` 가 후처리 — 작성자가 *enum 외 값*도 자유롭게 쓰는 관행이 굳어진 흔적. 새 액션 추가 시 매핑 누락 가능.
- 정규식이 *글로벌* — 룰 작성자가 `r"..."` 안에 backslash 두 번 박는 실수가 잦다. 본 데이터에는 보이지 않음.
- *대량 데이터 튜플 (약 90개)* — 변경 시 PR diff 가독성 ↓. 데이터를 YAML/CSV로 외부화하면 *코드 리뷰 부담* 가벼워질 수 있음 (속도/이식성 trade-off).

---

## Block 5 — `PRIVACY_OUTPUT_RULES` 데이터 본문 (라인 2386–2828, 약 84 룰)

대표 (라인 2386–2397):

```python path=scripts/gen-rules.py lines=2386-2397
PRIVACY_OUTPUT_RULES: list[tuple] = [
    ("national_id_kr", "critical", "redact", 950,
     "응답 내 주민등록번호 마스킹",
     "Redact RRNs that appear in model output.",
     "주민등록번호는 마스킹 처리됩니다.",
     "Korean RRN is redacted in responses.",
     ["KR_PIPA"],
     {"regex": [r"\b\d{6}[- ]?\d{7}\b"]},
     "고객 주민등록번호는 900101-1234567 입니다.",
     "주민등록번호 체계는 생년월일 6자리와 뒤 7자리로 구성됩니다.",
     "The customer's RRN is 900101-1234567.",
     "RRN structure: 6+7 digits."),
    ...
]
```

**분석 / Analysis (Level 2)**

- 입력 룰과 *동일 sub_category*를 재사용 (`national_id_kr`). io_type 만 *output* 으로 갈린다 → `emit_rules` 가 io_type 을 *외부에서* 주입 (라인 4275 `for io_type, src in [("input", input_rules), ("output", output_rules)]:`).
- 행동이 *input → block, output → redact* 로 다름. 일반 패턴: 입력은 차단, 출력은 마스킹. Defense-in-depth 설계.

**짚어볼 점 / Watch-outs**

- 두 리스트가 *대부분 같은 sub_category 를 반복* — 동기화 부담. 입력 룰 추가 시 출력 룰도 만들지 안 만들지 *명시적 선택*이 필요한데, 본 코드는 *둘이 별 리스트*라 누락 위험. *대안:* sub_category 별 dict (`{"national_id_kr": {"input": {...}, "output": {...}}}`)로 재구성하면 누락 즉시 발견.

---

## Block 6 — `MF_FOOD_INPUT_RULES` 데이터 (라인 2835–3751)

대표 (라인 2837–2847):

```python path=scripts/gen-rules.py lines=2835-2847
MF_FOOD_INPUT_RULES: list[tuple] = [
    # privacy
    ("employee_contact", "high", "block_or_redact", 870,
     "생산·품질 담당 직원 연락처 입력 차단",
     "Block plant employee phone/email input.",
     "직원 연락처 등 개인정보는 입력하지 마세요.",
     "Do not enter employee phone numbers or emails.",
     ["KR_PIPA"],
     {"regex": [r"\b01[016789][- .]?\d{3,4}[- .]?\d{4}\b"]},
     "야간조 반장 홍길동 010-1234-5678 연락처 추가.",
     "야간조 연락 체계 설계 시 고려사항?",
     "Line supervisor John 010-1234-5678 phone.",
     "Designing shift contact escalation?"),
    ...
]
```

**분석 / Analysis (Level 2)**

- *도메인 특화* (manufacturing-food). 룰 sub_category 가 PII (`employee_contact`) → safety / compliance / IP 로 확장 (대표: `dangerous_equipment_op`, `secret_recipe`, `expired_food_relabel`).
- 같은 *14-요소 튜플 포맷* — 데이터 sheet 일관성. 운영자가 한 번에 양 도메인 룰을 동일 viewer로 봄.
- *카테고리 라벨이 데이터에 없음* — `_category_for_mf_food()` 가 sub_category → category(`pii`/`safety`/`compliance`/`ip`) 를 set 매핑으로 결정. 매핑 누락 시 *default `pii`* 로 떨어진다.

**짚어볼 점 / Watch-outs**

- `_category_for_mf_food` default `"pii"` — sub_category 가 *어느 set 에도 없으면* 조용히 PII 로. *오탈자 검출 없음*. **권고: KeyError 또는 warning print**.
- *식품 안전 / 위생 관련 텍스트가 한국어 + 영어* — 도메인 전문가가 룰을 추가할 때 *번역 품질* 검증이 별도 프로세스로 필요.

---

## Block 7 — `MF_FOOD_OUTPUT_RULES` 데이터 (라인 3753–4256)

대표 (라인 3753–3766):

```python path=scripts/gen-rules.py lines=3753-3766
MF_FOOD_OUTPUT_RULES: list[tuple] = [
    ("employee_name_out", "high", "generalize_or_redact", 850,
     "리포트 응답에서 직원 실명 일반화",
     "Generalize employee real names in reports.",
     "보고서에서는 \"작업자 A\" 식으로 일반화합니다.",
     "Use generic labels like 'Operator A' instead of real names.",
     ["KR_PIPA"],
     None,
     "포장라인 사고는 김OO, 이OO에 집중되었다.",
     "포장라인 사고는 일부 작업자에 집중되었다.",
    ...
]
```

**분석 / Analysis (Level 2)**

- 출력 룰의 *대표 액션*: `generalize_or_redact`. `non_std_map` 이 `→ redact` 로 매핑(라인 4292). “일반화(generalize)”의 *완전한 의미* 가 enum 안에는 없어, *현실적인 대안*인 redact 로 다운그레이드.
- patterns `None` — *regex 기반 검출 없음*. 즉 *분류기/LLM 기반 룰*. `emit_rules` 가 `pattern_type` 을 `"classifier"` 로 설정.

**짚어볼 점 / Watch-outs**

- `pattern_type="classifier"` 가 부여되어도, *어떤 classifier* 인지는 룰 데이터에 없음. Detection Engine 측 매핑 의존. 형제 서비스 변경 시 호환성 깨질 위험.

---

## Block 8 — `emit_rules()` 본체 (라인 4262–4341)

```python path=scripts/gen-rules.py lines=4262-4341
def emit_rules(
    *,
    domain: str,
    locale: str,
    input_rules: list[tuple],
    output_rules: list[tuple],
    file_basename: str,
    id_prefix: str,
) -> Path:
    rules_out: list[dict] = []
    global_idx = 0
    # input first, then output — ruleId numbered sequentially across both blocks
    # so the bundle's last ruleId equals totalRules (no per-io-type reset).
    for io_type, src in [("input", input_rules), ("output", output_rules)]:
        for t in src:
            global_idx += 1
            (sub_cat, sev, action, prio,
             desc_ko, desc_en, msg_ko, msg_en,
             reg_tags, patterns,
             ex_pos_ko, ex_neg_ko, ex_pos_en, ex_neg_en) = t
            # Map any "non-standard" action strings to schema-valid actions.
            action_mapped = action
            non_std_map = {
                "advise_pseudonymization": "warn",
                "advise_minimization": "warn",
                "block_or_warn": "block_or_redact",
                "block_or_generalize": "redact",
                "block_or_summarize": "block_or_redact",
                "block_or_pseudonymize": "block_or_pseudonymize",
                "block_or_route": "block_or_redact",
                "generalize_or_redact": "redact",
                "generalize_or_refuse": "redact",
                "generalize": "redact",
                "remove": "redact",
                "remove_or_anonymize": "redact",
                "refuse_or_anonymize": "refuse",
                "block_and_support": "block",
                "add_compliance_notice": "add_disclaimer",
                "block_or_aggregate": "aggregate_only",
            }
            action_mapped = non_std_map.get(action_mapped, action_mapped)
            desc = desc_ko if locale == "ko-KR" else desc_en
            ex_pos = [ex_pos_ko] if locale == "ko-KR" else [ex_pos_en]
            ex_neg = [ex_neg_ko] if locale == "ko-KR" else [ex_neg_en]
            rid = f"{id_prefix}_{global_idx:03d}"
            r = RuleSpec(
                rule_id=rid,
                domain=domain,
                locale=locale,
                io_type=io_type,
                category=(
                    _category_for_global(sub_cat)
                    if domain == "global"
                    else _category_for_mf_food(sub_cat)
                ),
                sub_category=sub_cat,
                description=desc,
                pattern_type="regex" if (patterns and "regex" in patterns) else "classifier",
                severity=sev,
                priority=prio,
                action=action_mapped,
                message=msg(msg_ko, msg_en),
                regulation_tags=list(reg_tags),
                examples_positive=ex_pos,
                examples_negative=ex_neg,
                patterns=patterns,
            )
            rules_out.append(r.to_dict())
    bundle = {
        "$schema": "https://example.com/guardrails/rule-bundle.schema.json",
        "domain": domain,
        "locale": locale,
        "generatedAt": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
        "totalRules": len(rules_out),
        "rules": rules_out,
    }
    out_path = SCRIPT_DIR / file_basename
    out_path.write_text(json.dumps(bundle, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"wrote {out_path.relative_to(SCRIPT_DIR.parent)}: {len(rules_out)} rules")
    return out_path
```

**분석 / Analysis (Level 2)**

- `*,` 키워드-온리 인자 — 호출 시 *항상 명시 이름 지정*. positional 혼동 방지.
- `global_idx` — 입력+출력에 *교차 증가*. ruleId 가 `PRIV_KR_001` … `PRIV_KR_N` 형태로 *bundle 단위 sequential*. *왜:* `init-db.sql` 의 `rule_id TEXT PRIMARY KEY` 가 *전역 unique*해야 → bundle 내 sequential 이라도 prefix 가 도메인+로케일 별로 다르면 충돌 없음.
- `non_std_map` — 16개 비표준 액션을 enum 으로 다운매핑. `block_or_pseudonymize` 가 *자기 자신*으로 매핑됨(라인 4290) — *redundant*. 의도: enum에 이미 있는 값이지만 *명시적 화이트리스트* 표기로 남긴 듯.
- `action_mapped = non_std_map.get(action_mapped, action_mapped)` — get fallback. **enum 외 값이 매핑에 없으면 원본 그대로 통과**. Risk Hotspot.
- 로케일 분기 — `desc/ex_pos/ex_neg` 만 *해당 로케일*만 유지. `message` 는 *양 로케일 dict*로 유지 (Policy Engine 응답 시 `Accept-Language` 협상 가정).
- `pattern_type = "regex" if (patterns and "regex" in patterns) else "classifier"` — *patterns dict 에 `regex` 키가 있으면* regex, 아니면 classifier. 정규식 외 패턴 타입(예: glob, embedding)은 *현 시점 미고려*.
- `regulation_tags=list(reg_tags)` — 원본 리스트의 *얕은 복사*. 입력 데이터의 리스트가 다른 룰과 *공유 참조*가 아닌 한 안전. (실제 데이터 튜플마다 새 리스트 리터럴)
- bundle 메타: `$schema`, `domain`, `locale`, `generatedAt`, `totalRules`, `rules`. `$schema` URL이 `example.com` — *placeholder*. 실제 schema 서버가 없으면 validator 가 못 풀음.
- `generatedAt = datetime.now(timezone.utc).replace(microsecond=0).isoformat()` — *마이크로초 제거*. byte-stable 약속을 *모든 다른 필드와 함께* 지키되 *시각만* 갱신. PR diff 가 매 실행마다 한 줄 변화로 제한.
- `json.dumps(..., ensure_ascii=False, indent=2)` — 한국어 그대로 출력 (non-ASCII escape 안 함) + 2-space indent. JSON 비교 시 *문자 그대로* 보임.
- `print(f"wrote {out_path.relative_to(SCRIPT_DIR.parent)}: {len(rules_out)} rules")` — stdout 진행 출력. CI 로그에 적합.

**짚어볼 점 / Watch-outs**

- **enum 외 액션 silent fallthrough**: `action_mapped = non_std_map.get(action_mapped, action_mapped)` 의 두 번째 인자가 *원본* 이라 매핑 누락 시 그대로. **권고: `assert action_mapped in ACTIONS`** 한 줄 추가.
- `block_or_pseudonymize → block_or_pseudonymize` 같은 *항등 매핑*은 enum 화이트리스트 의도이지만 코드 의도가 *주석* 없이 흐른다.
- `generatedAt` 가 *UTC, ISO 8601, 초 단위* — JSON diff 에서 매 실행 한 줄 변경. *어떤 PR도 이 한 줄을 commit* 하게 되어 노이즈. *대안:* `--check` 모드(diff 검증) 와 `--write` 모드 분리, CI 에선 `--check` 만.
- `json.dumps` 의 `indent=2` — 큰 JSON에서 *공백 비용*. Policy Engine 부팅 적재 비용이 의미 있는 수준이면 indent=None 검토 (운영자 가독성 trade-off).
- `relative_to(SCRIPT_DIR.parent)` 가 *부모 디렉토리 기준*. `scripts/` 가 *서브디렉토리*임을 전제 — 디렉토리 구조 변경 시 ValueError 가능.

---

## Block 9 — 카테고리 매핑 (라인 4344–4498)

```python path=scripts/gen-rules.py lines=4344-4498
_GLOBAL_CATEGORY_RULES: dict[str, str] = {
    # credentials
    "password": "credentials", "otp_2fa": "credentials", ...
    # financial
    "card_number": "financial", ...
    # health
    "patient_record": "health", ...
    # location
    "home_address_combo": "location", ...
    # biometrics
    "face_embedding": "biometrics", ...
    # sensitive
    "political_affiliation": "sensitive", ...
    # children
    "minor_full_id": "children", ...
    # logs / misc
    "raw_access_logs": "pii", "ipv4_combo": "pii", ...
}


def _category_for_global(sub_cat: str) -> str:
    return _GLOBAL_CATEGORY_RULES.get(sub_cat, "pii")


_MF_FOOD_IP = { ... }
_MF_FOOD_COMPLIANCE = { ... }
_MF_FOOD_SAFETY = { ... }


def _category_for_mf_food(sub_cat: str) -> str:
    """Map manufacturing-food sub-category to PRD category enum."""
    if sub_cat in _MF_FOOD_IP:
        return "ip"
    if sub_cat in _MF_FOOD_COMPLIANCE:
        return "compliance"
    if sub_cat in _MF_FOOD_SAFETY:
        return "safety"
    return "pii"
```

**분석 / Analysis (Level 2)**

- `_GLOBAL_CATEGORY_RULES` — sub_category 단위로 category 라벨을 *dict 룩업*. default `"pii"` 로 fallback.
- `_MF_FOOD_*` 는 *set* 기반 — 분류 우선순위가 *IP > COMPLIANCE > SAFETY > pii(default)*. 순서가 의미적 우선순위를 반영. *왜:* 한 sub_category 가 두 카테고리에 *동시에* 들어가지 않는다는 약속.
- 두 헬퍼가 *외부 가시성 명시*: `_` 접두 → 모듈 외부 의도 안 함.

**짚어볼 점 / Watch-outs**

- *데이터 sub_category 명*과 *매핑 dict/set 의 키* 가 *문자열 동기화*되어야 함. 한 군데 오타 시 default `"pii"` 로 *조용히 떨어짐*. **권고: emit_rules 시점에 *매핑되지 않은 sub_category 가 default 로 떨어졌으면 stderr 경고*.**
- `_MF_FOOD_*` set 멤버 중복 시 *우선순위 효과 없음* (set membership). 데이터 추가 시 “두 카테고리에 같은 sub_cat이 등록되면 우선순위가 적용”을 *주석으로 명시*하면 좋다.
- `dict[str, str]` 어노테이션 — Python 3.9+. 본 코드 `from __future__ import annotations` 덕에 안전.

---

## Block 10 — `main()` + entrypoint (라인 4501–4539)

```python path=scripts/gen-rules.py lines=4501-4539
def main() -> None:
    # Privacy bundles
    emit_rules(
        domain="global",
        locale="ko-KR",
        input_rules=PRIVACY_INPUT_RULES,
        output_rules=PRIVACY_OUTPUT_RULES,
        file_basename="privacy.kr.json",
        id_prefix="PRIV_KR",
    )
    emit_rules(
        domain="global",
        locale="en",
        input_rules=PRIVACY_INPUT_RULES,
        output_rules=PRIVACY_OUTPUT_RULES,
        file_basename="privacy.en.json",
        id_prefix="PRIV_EN",
    )
    # Manufacturing.Food bundles
    emit_rules(
        domain="manufacturing-food",
        locale="ko-KR",
        input_rules=MF_FOOD_INPUT_RULES,
        output_rules=MF_FOOD_OUTPUT_RULES,
        file_basename="manufacturing-food.kr.json",
        id_prefix="MF_FOOD_KR",
    )
    emit_rules(
        domain="manufacturing-food",
        locale="en",
        input_rules=MF_FOOD_INPUT_RULES,
        output_rules=MF_FOOD_OUTPUT_RULES,
        file_basename="manufacturing-food.en.json",
        id_prefix="MF_FOOD_EN",
    )


if __name__ == "__main__":
    main()
```

**분석 / Analysis (Level 2)**

- 4번의 `emit_rules` 호출 — 도메인 2 × 로케일 2. *명시적 펼침* (loop 없음). 이유: 향후 *bundle 별로 옵션이 달라질* 여지가 있다는 보호적 코드 스타일.
- `id_prefix` 가 도메인+로케일 별로 *고유* — DB unique PK 보장.
- `if __name__ == "__main__":` — *모듈 임포트 시* 자동 실행 방지. 테스트 코드가 `import gen_rules` 후 `gen_rules.PRIVACY_INPUT_RULES` 만 검사 가능.

**짚어볼 점 / Watch-outs**

- 명시적 4 호출 — 새 (도메인, 로케일) 페어 추가 시 *4가지를 모두 잊지 않고 작성*해야 함. 도메인 수가 늘어나면 loop 화 검토.

---

## 파일 수준 평가 / File-Level Verdict

- 강점 / Strengths:
  1. *외부 의존 0* (stdlib only) — 어떤 Python 3.10+ 환경에서도 실행.
  2. *결정적·idempotent* 약속이 docstring에 명시되어 PR diff 가 *최소*.
  3. 데이터(룰 본체)와 schema/매핑(emit_rules + 카테고리 함수) 분리.
  4. `RuleSpec` dataclass + `to_dict()` 로 *형제 TS schema와의 키 변환*을 한 곳에 격리.
  5. `non_std_map` 으로 *데이터 작성자의 자유도*와 *schema 엄격성* 사이의 균형.
- 위험 / Risks:
  1. **enum 외 액션이 매핑 누락 시 silent passthrough**. 운영 사고 잠재화.
  2. `_category_for_*` 의 *default fallback `pii`* 가 sub_category 오타 검출 불가능.
  3. 룰 데이터가 *14-요소 positional tuple* — 컬럼 순서 오류 검출 수단 부재.
  4. 입력/출력 룰이 *별 리스트*로 분리 — 누락 시 발견 어려움.
  5. `generatedAt` 가 매 실행마다 한 줄 diff — PR 노이즈.
- 개선 권고 / Recommendations (impact 순):
  1. `emit_rules` 마지막에 `assert action_mapped in ACTIONS, f"unknown action {action!r} at {rid}"` 추가.
  2. `_category_for_*` 가 매핑 누락 시 `print(f"warn: {sub_cat} → default pii", file=sys.stderr)` 또는 raise.
  3. 14-요소 tuple 을 *namedtuple* 또는 *TypedDict* 로 전환 — 컬럼 명시화. 데이터 가독성 유지를 위해 helper builder (`R(sub="...", sev="...", ...)`) 도입 검토.
  4. 입력+출력 룰을 `RULES[sub_cat] = {"input": ..., "output": ...}` 형태로 재구성, 누락 시 즉시 가시.
  5. `--check` 모드 추가 (CI 에서 데이터 변경 detect → `generatedAt` 만 다른 경우 무시).
  6. dead import (`field`, `Callable`, `Iterable`) 제거.
- 재읽기 권고 레벨 / Suggested re-read level: **3** — generator 설계 결정과 schema sync 의 *왜* 까지 시니어 시점 재고.
