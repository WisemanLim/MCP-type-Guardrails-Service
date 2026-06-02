# INGEST-GUIDE.md — 가드레일 룰 데이터 수집 가이드

Guardrails-Service 가드레일 정책 룰의 **수집·작성·적재** 표준 문서.
이 문서 하나로 (1) 현재 보유 데이터 현황, (2) 데이터 스키마, (3) 도메인 확장 로드맵과 분야별 수집 목표,
(4) 신규 도메인 추가 절차를 모두 확인할 수 있다. 별도 PRD 없이 단독으로 데이터 작업을 진행할 수 있도록 구성했다.

- 대상 산출물: `scripts/<domain>.<locale>.json` 룰 번들
- 진실원본(source of truth): `scripts/*.json` 의 `domain` 필드 + 본 문서의 목표 수치
- 생성기: `scripts/gen-rules.py` (deterministic / idempotent)
- 적재 경로: `scripts/init-db.sql` (스키마) → Policy Engine 부팅 시 bulk insert → `rules` 테이블

> **현행 도메인 모델 주의 (MCP-type-Guardrails-Service)**
> 본 프로젝트의 현재 시드(`scripts/privacy.{kr,en}.json`)는 `domain="global"` 로
> 적재된다 — privacy 룰셋을 별도 leaf 도메인으로 분리하지 않고 `global` baseline 에
> 직접 포함하는 모델이다. `manufacturing-food` 는 `manufacturing → global` 로 상속한다.
> 아래 본문의 `domain=privacy` (global 로 체인되는 별도 leaf) 서술은 **권장 목표 모델**
> (DocuGuard-AI 계열 reference 설계)이며, 현행과 다르다. privacy 를 leaf 로 분리하려면
> seed `domain` 필드 + `scripts/init-db.sql` 의 도메인 INSERT + Policy Engine 도메인
> 리졸버 + `docker-compose.privacy.yml` 마운트 경로를 함께 변경해야 한다(동작 변경 — 신중).

---

## 1. 현재 수집 현황 (Phase 1–2)

### 1.1 파일 인벤토리

| 파일 | `domain` | `locale` | rule 수 | 크기 | Phase | 상태 |
|---|---|---|---:|---:|---|---|
| `scripts/privacy.kr.json` | `global` *(현행)* | `ko-KR` | **245** | ~205 KB | P1 | GA |
| `scripts/privacy.en.json` | `global` *(현행)* | `en` | **245** | ~202 KB | P1 | GA |
| `scripts/manufacturing-food.kr.json` | `manufacturing-food` | `ko-KR` | **127** | ~111 KB | P2 | 초안 |
| `scripts/manufacturing-food.en.json` | `manufacturing-food` | `en` | **127** | ~108 KB | P2 | 초안 |
| (baked) `policies/global/privacy/*.json` | `global` | ko-KR/en | **21** | — | P1 | GA, Policy 이미지 내장 |

- 합계: 룰 인스턴스 **744개** (privacy 번들 490(현행 `domain=global`) + `manufacturing-food` 254), baked `global` 21 별도.
- ko-KR ↔ en 은 **1:1 미러**. 동일 인덱스의 룰이 locale만 다르게 존재(룰 수·subCategory 동일, `ruleId` 접미만 상이).
- **현행**: privacy 번들은 `domain=global` 로 적재 → `global` baseline 에 직접 포함. `manufacturing-food` 는 `manufacturing → global` 로 상속.
- **권장 목표**: privacy 를 `global` 로 체인되는 **별도 leaf 도메인**(`domain=privacy`)으로 분리하면 `GUARDRAILS_ENABLED_DOMAINS` 로 245룰 baseline 만 선택적 토글 가능(동작 변경 필요 — 상단 주의 참고).

### 1.2 번들 래퍼 스키마

모든 시드 파일 최상위 객체:

```json
{
  "$schema": "https://example.com/guardrails/rule-bundle.schema.json",
  "domain": "privacy",
  "locale": "ko-KR",
  "generatedAt": "2026-05-27T07:05:39+00:00",
  "totalRules": 245,
  "rules": [ /* GuardrailRule[] */ ]
}
```

| 필드 | 타입 | 규칙 |
|---|---|---|
| `$schema` | string(URI) | 고정. 번들 식별자 |
| `domain` | string | 도메인 키. Policy loader가 읽는 **진실원본**(파일명 아님) |
| `locale` | string | `ko-KR` \| `en` \| `ja-JP` … 번들 내 전 룰 동일 |
| `generatedAt` | string(ISO8601) | gen-rules.py 실행 시각. byte-stable 비교 시 제외 대상 |
| `totalRules` | int | `rules.length` 와 일치 강제 |
| `rules` | GuardrailRule[] | 본체 |

### 1.3 GuardrailRule 필드 스키마 (실측 18 필드)

`patterns` 는 optional, 나머지 17개는 모든 룰에 존재.

| 필드 | 타입 | enum / 형식 | 필수 | 비고 |
|---|---|---|:--:|---|
| `ruleId` | string | `<PREFIX>_<LOCALE>_<NNN>` | ✅ | PK. 예 `PRIV_KR_001`, `MF_FOOD_EN_127` |
| `domain` | string | 도메인 키 | ✅ | 번들 `domain` 과 동일 |
| `locale` | string | `ko-KR`\|`en`\|`*` | ✅ | 번들 `locale` 과 동일 |
| `ioType` | string | `input`\|`output`\|`both` | ✅ | 평가 단계 |
| `category` | string | 아래 카테고리 enum | ✅ | 1차 분류 |
| `subCategory` | string | free-text snake_case | ✅ | 2차 분류. 도메인 내 **고유 권장** |
| `description` | string | 자연어 | ✅ | 룰 의도(locale별) |
| `patternType` | string | `regex`\|`keyword`\|`classifier`\|`llm_classifier`\|`regex+classifier`\|`generator_policy` | ✅ | 매칭 방식 |
| `severity` | string | `low`\|`medium`\|`high`\|`critical` | ✅ | 위험도 |
| `priority` | int | 0–1000 | ✅ | 높을수록 우선. 머지 동률 해소 |
| `action` | string | 아래 action enum | ✅ | 판정 결과 |
| `messageTemplate` | object | `{ "<locale>": string }` | ✅ | 사용자 노출 메시지(ko-KR+en 동시 권장) |
| `regulationTags` | string[] | 규제 코드 | ✅ | 빈 배열 허용(credentials류) |
| `examplesPositive` | string[] | 매치되어야 할 예시 | ✅ | 회귀 테스트 시드 |
| `examplesNegative` | string[] | 매치되면 안 되는 예시 | ✅ | 오탐 방지 시드 |
| `enabled` | boolean | — | ✅ | 시드는 전부 `true` |
| `version` | string | semver | ✅ | 시드는 `1.0.0` |
| `patterns` | object | `{regex[], keywords[], entities[], luhnCheck, minContextWindow, requiresPersonLink}` | ⬜ | `regex`/`regex+classifier` 일 때만. `classifier` 룰은 생략 |

**`category` enum (실측 사용값)**: `pii`, `financial`, `credentials`, `health`, `location`,
`biometrics`, `sensitive`, `children`, `scope`, `hallucination`, `compliance`, `safety`, `ip`.
추가 예약: `fraud`, `prompt_injection`.

**`action` enum (실측 사용값)**: `allow`, `warn`, `redact`, `sanitize`, `block`,
`block_or_redact`, `block_or_pseudonymize`, `aggregate_only`, `refuse`, `add_disclaimer`, `escalate`, `route`.

### 1.4 `ruleId` 명명 규칙

```
<PREFIX>_<LOCALE2>_<NNN>
        │        │      └ 3자리 zero-pad 일련번호, 번들 내 1부터 연속
        │        └ KR | EN  (ja-JP 추가 시 JP)
        └ 도메인 약어:  PRIV (privacy) · MF_FOOD (manufacturing-food)
```

신규 도메인 PREFIX 표준:

| 도메인 키 | PREFIX |
|---|---|
| `manufacturing-chemical` | `MF_CHEM` |
| `manufacturing-pharma` | `MF_PHARMA` |
| `manufacturing-automotive` | `MF_AUTO` |
| `manufacturing-electronics` | `MF_ELEC` |
| `finance-banking` | `FIN_BANK` |
| `finance-insurance` | `FIN_INS` |
| `finance-securities-misc` | `FIN_SEC` |
| `healthcare-clinical` | `HC_CLIN` |
| `public-administration` | `PUB_ADM` |

### 1.5 카테고리 분포 — `privacy` (245룰, ko-KR 기준)

| category | input | output | 합계 | 대표 subCategory |
|---|---:|---:|---:|---|
| `pii` | 80 | 22 | **102** | national_id_kr, ssn_us, mynumber_jp, passport, email, phone_* |
| `financial` | 25 | 2 | **27** | card_number(+luhn), iban, bank_account_kr, crypto_seed_phrase |
| `health` | 22 | 4 | **26** | patient_record, diagnosis_with_name, genetic_info, self_harm_method |
| `credentials` | 21 | 3 | **24** | password, otp_2fa, aws_key, ssh_private_key, jwt_token |
| `location` | 15 | 2 | **17** | address_*_full, gps_coord_with_name, real_time_location |
| `sensitive` | 14 | 2 | **16** | political_affiliation, religion_with_name, race_ethnicity |
| `children` | 14 | 1 | **15** | minor_full_id, minor_photo_ref, minor_school_combo |
| `biometrics` | 7 | 1 | **8** | face_embedding, fingerprint_template, dna_sequence |
| `scope` | 6 | 1 | **7** | linkage_attack, k_anonymity_violation, cross_border_transfer |
| `hallucination` | 0 | 2 | **2** | fabricated_law_citation, hallucinated_pii_warning |
| `compliance` | 1 | 0 | **1** | dp_budget_warning |
| **합계** | **205** | **40** | **245** | unique subCategory ≈ 234 |

- ioType 비중 input:output ≈ **84:16**. 출력 검증 룰은 보강 여지(아래 §5 목표에 반영).
- 규제 커버리지: `KR_PIPA`(133) · `EU_GDPR`(50) · `EU_GDPR_Art9`(43) · `US_HIPAA`(26) · `US_CCPA`(18) · `COPPA`(18) · `PCI_DSS`(7) · `JP_APPI`(6) + 다국가(NHS/PIPEDA/DPDP/LGPD…) 산발.

### 1.6 카테고리 분포 — `manufacturing-food` (127룰, ko-KR 기준)

| category | input | output | 합계 | 대표 subCategory |
|---|---:|---:|---:|---|
| `compliance` | 52 | 15 | **67** | allergen_*_omit(9종), haccp_bypass, expired_food_relabel, organic_misclaim, nutrition_table_fake |
| `pii` | 13 | 17 | **30** | employee_contact, worker_health, consumer_complaint, supplier_contact, cctv_identify |
| `safety` | 12 | 4 | **16** | ppe_skip, confined_space_entry, ammonia_leak_cover, metal_in_food |
| `ip` | 5 | 9 | **14** | secret_recipe, process_parameters, supplier_pricing, rnd_formulation |
| **합계** | **82** | **45** | **127** | unique subCategory = 127 |

- ioType input:output ≈ **65:35** (식품 도메인은 응답에 영업비밀/허위표시가 새는 시나리오가 많아 출력 검증 비중이 높음).
- 규제: `KR_FSC`(식품위생법, 55) · `KR_PIPA`(32) · `US_FDA`(29) · `TRADE_SECRET`(14) · `KR_OSH`(14) · `EU_1169_2011`(11) · `US_FDA_FALCPA`(10) + HACCP/FSMA/USDA/EFSA 등.

### 1.7 DB 적재 모델 (`scripts/init-db.sql`)

- `rules` 테이블이 시드의 종착지. 컬럼 매핑: `pattern_bundle ← patterns`, `message_template ← messageTemplate`, 나머지 동명.
- 추가 컬럼 `source TEXT CHECK (source IN ('file','admin','csv'))` — 시드 적재분은 `file`.
- `domains` 테이블에 도메인 키가 **선행 존재**해야 `rules.domain` FK 충족. `init-db.sql` 이 `global → manufacturing → manufacturing-food` 순으로 사전 INSERT(부모 먼저). 신규 도메인 추가 시 동일 패턴으로 INSERT 추가 필수.
- `inherits_from TEXT[]` 가 머지 체인을 표현(`manufacturing-food` → `['manufacturing','global']`).

---

## 2. 데이터 품질 규약 (수집 시 강제)

신규 룰 1건을 "완성"으로 인정하는 최소 조건(Definition of Done):

1. **locale 쌍 의무**: 모든 룰은 `ko-KR` + `en` 두 번들에 동일 인덱스로 존재. (ja-JP는 도메인별 선택)
2. **예시 의무**: `examplesPositive` ≥ 1, `examplesNegative` ≥ 1. negative는 "용어 설명/제도 질의" 같은 **정상 우회 케이스**를 넣어 오탐 방지.
3. **patternType ↔ patterns 정합**:
   - `regex` / `regex+classifier` → `patterns.regex[]` 필수. 식별번호류는 `luhnCheck`/`requiresPersonLink` 병기.
   - `classifier` / `llm_classifier` → `patterns` 생략(의미 기반).
   - `keyword` → `patterns.keywords[]` 필수.
4. **messageTemplate**: 노출 locale 전부 채움(`ko-KR`+`en`). block/refuse 계열은 사유 명시.
5. **severity ↔ action 일관성** (권장 매핑):
   | severity | 기본 action |
   |---|---|
   | critical | `block` / `refuse` |
   | high | `block_or_redact` / `block_or_pseudonymize` / `redact` |
   | medium | `redact` / `warn` / `add_disclaimer` |
   | low | `warn` / `allow` |
6. **priority 대역**: critical 900–990 · high 800–890 · medium 400–700 · low 150–350. (privacy 실측 150–990, food 400–920)
7. **subCategory 고유성**: 동일 도메인 내 중복 금지(food 기준 127 unique/127 권장).
8. **regulationTags**: 최소 1개. credentials처럼 규제 직접 매핑이 없으면 `[]` 허용하되 description에 근거 명시.

---

## 3. 도메인 표준 카테고리 배분 템플릿 (목표 200룰)

§5 각 분야 목표(≥200)를 채울 때의 **기본 배분 골격**. 도메인 특성에 따라 ±조정하되 합계 ≥200, output 비중 ≥30% 유지.

| category | 룰 수 | input:output | 설명 |
|---|---:|---|---|
| `pii` | 45 | 28:17 | 도메인 맥락의 인적정보(직원/고객/공급사/피험자 등) |
| `compliance` | 70 | 45:25 | 도메인 규제 위반(법령 세조항 매핑) |
| `safety` | 30 | 20:10 | 작업/제품/공정 안전 |
| `ip` | 25 | 8:17 | 영업비밀·도면·레시피·공정 비밀 |
| `fraud` | 20 | 14:6 | 허위표시·은폐·조작 권유 |
| `scope`+`hallucination` | 15 | 5:10 | 범위 이탈·환각(법령/수치 날조) |
| **합계** | **205** | ≈120:85 | output 비중 ≈ 41% |

> 비제조 도메인(finance/healthcare/public)은 `safety`/`ip` 비중을 낮추고 `compliance`/`financial`/`health` 를 키운다(§5 각 phase 비고 참조).

---

## 4. 도메인 키 — 산업분류 매핑

도메인 키는 **ISIC Rev.4 Section/Division** 구조와 1:1 매핑되며, 동일 노드에 KSIC·NACE·NAICS 코드를 함께 태깅한다.
단계적 확장은 (a) 산업 분류상 인접성, (b) 규제 압력(개인정보·안전), (c) 시장 수요 우선순위 기준으로 정한다.
명명 규칙: `<industry>-<sub_industry>[-<function>]` (더 세분화 시 `<industry>-<sub>-<class>`, 예 `manufacturing-automotive-battery`).

```
domain_key                          ISIC Rev.4   KSIC      NACE Rev.2   NAICS
─────────────────────────────────── ───────────  ──────    ─────────    ──────
global                              —            —         —            —
manufacturing                       Section C    C         C            31-33
manufacturing-food                  10           10        10           311
manufacturing-beverage              11           11        11           312
manufacturing-tobacco               12           12        12           3122
manufacturing-textile               13           13        13           313-314
manufacturing-apparel               14           14        14           315
manufacturing-chemical              20           20        20           325
manufacturing-pharma                21           21        21           3254
manufacturing-rubber-plastics       22           22        22           326
manufacturing-metal-primary         24           24        24           331
manufacturing-electronics           26           26        26           334
manufacturing-electrical            27           28        27           335
manufacturing-machinery             28           29        28           333
manufacturing-automotive            29           30        29           3361-3363
manufacturing-other-transport       30           31        30           3364-3369
finance-banking                     64           64        64           522
finance-insurance                   65           65        65           524
finance-securities-misc             66           66        66           523
healthcare-clinical                 86           86        86           621-622
healthcare-residential-welfare      87           87        87           623
healthcare-non-residential-welfare  88           88        88           624
public-administration               84           84        84           92
ict-software                        62           62        62           5415
ict-info-services                   63           63        63           519
retail-wholesale                    46           46        46           42
retail-stores                       47           47        47           44-45
transport-logistics                 49-53        49-53     49-53        48-49
energy-utilities                    35           35        35           22
construction                        41-43        41-43     41-43        23
education                           85           85        85           61
arts-recreation                     90-93        90-92     90-93        71
agriculture                         01-03        01-03     01-03        11
```

---

## 5. 단계별(Phase) 수집 로드맵 — 분야별 목표 ≥200

각 phase는 독립 배포를 보장한다(이전 phase 결과물 단독 구동 가능, `docker-compose.<phase>.yml` overlay 추가만으로 확장).
"현재"는 실측 시드, "목표"는 production 수집 목표(ko-KR/en 각각, 분야별 **최소 200룰**).

### 5.0 요약 표

| Phase | domain_key | ISIC / KSIC | 핵심 규제 | 현재(룰/locale) | **목표 ≥200** | 우선 카테고리 |
|---|---|---|---|---:|---:|---|
| **P1** ✅ | `privacy` (+`global`) | cross-cutting | PIPA·GDPR·HIPAA·CCPA·APPI·COPPA·PCI | 245 | **260** | pii·financial·health·credentials (output 보강) |
| **P2** 🛠 | `manufacturing-food` | C10 / KSIC10 | 식품위생법·표시광고법·FDA·FALCPA·HACCP·OSH | 127 | **200** | compliance·pii·safety·ip |
| **P3** | `manufacturing-chemical` | C20 / KSIC20 | 화관법·REACH·TSCA·MSDS·OSHA HazCom | 0 | **200** | safety·compliance·ip·pii |
| **P4** | `manufacturing-pharma` | C21 / KSIC21 | 약사법·GMP·21 CFR Part11·EMA·ICH-GCP·HIPAA | 0 | **210** | compliance·ip·pii |
| **P5** | `manufacturing-automotive` | C29 / KSIC30 | 자동차관리법·리콜·UNECE WP.29·ISO 26262·SOTIF | 0 | **200** | safety·ip·compliance |
| **P6** | `manufacturing-electronics` | C26 / KSIC26 | 전안법·RoHS·CE·FCC·수출통제(EAR/ITAR) | 0 | **200** | ip·compliance·safety |
| **P7** | `finance-banking`·`finance-insurance`·`finance-securities-misc` | K / KSIC64–66 | 자본시장법·금소법·전금법·FATCA·MiFID II·GLBA·AML/KYC | 0 | **200×3=600** | compliance·financial·fraud·pii |
| **P8** | `healthcare-clinical` | Q86 / KSIC86 | 의료법·HIPAA·GDPR Art.9·원격의료·FDA SaMD | 0 | **220** | health·pii·compliance·hallucination |
| **P9** | `public-administration` | O84 / KSIC84 | 행정절차법·정보공개법·PIPA·청탁금지법 | 0 | **200** | compliance·pii·scope |
| **P10+** | ict·retail·transport·energy·education·construction·agriculture | KSIC62/63/46/47/H/35/85/F/A | FERPA·PIPA(학생)·도메인 개별 | 0 | **각 200** | §3 템플릿 적용 |

전 분야 목표 합계(핵심 10개 도메인 + 금융 3종): **약 2,700룰 × 2 locale ≈ 5,400 인스턴스**.

### Phase 1 — `global` + `privacy` (Privacy & Common Safety) ✅

- ISIC: 모든 Section 공통 적용 (cross-cutting)
- 규제: KR_PIPA, EU_GDPR(Art.5/Art.9/Art.10), US_HIPAA, US_CCPA, JP_APPI, COPPA, PCI_DSS
- 현재: `privacy` 245룰(ko-KR/en 각), `global` 21룰 baked
- 카테고리: pii / financial / credentials / health / location / biometrics / sensitive / children / scope / compliance / hallucination
- 배포: `docker-compose.yml` + `docker-compose.privacy.yml`
- **수집 목표: 260** (보강 +15). output 검증 보강 위주:
  - `pii` output: 직원/고객 PII가 생성 응답·요약·CSV로 새는 케이스 +10
  - `financial`/`credentials` output: 응답 내 카드·계좌·토큰 노출 +5
  - ja-JP 번들 신설은 P1 범위 밖(형태소기 선정 후).
- 상태: **GA (완료)**

### Phase 2 — `manufacturing-food` (KSIC 10 / ISIC 10) 🛠

- ISIC C10, KSIC 10, NACE 10, NAICS 311
- 규제: KR_FSC(식품위생법), 식품 표시광고법, KR_OSH, US_FDA(FALCPA/HACCP), EU_FOOD, TRADE_SECRET
- 현재: 127룰 초안(pii=30, compliance=67, safety=16, ip=14)
- 배포 조합: `docker-compose.yml` + `docker-compose.privacy.yml` + `docker-compose.food.yml` / 머지 순서 `global → manufacturing → manufacturing-food`
- **수집 목표: 200** (+73). 보강 분배:
  - `compliance` 67 → **95**: 식품위생법 세조항 매핑(첨가물 기준치, 표시기준, 잔류농약 PLS), EU 1169/2011 영양표시 세분
  - `pii` 30 → **40**: 협력사·운송기사·소비자 클레임 응답 누출 케이스
  - `safety` 16 → **35**: 작업안전(KR_OSH) 세분 — 밀폐공간·고소작업·암모니아·컨베이어
  - `ip` 14 → **30**: 레시피·공정파라미터·R&D 파이프라인 추론(competitor inference) 강화
  - whitelist `whitelists/manufacturing-food.<locale>.json`: 식품 일반용어·법령 인용 예외
  - 테스트 케이스 100+ (정상/edge/우회 6:3:1)
- 상태: **개발 중 (1차 초안)**

### Phase 3 — `manufacturing-chemical` (KSIC 20 / ISIC 20)

- ISIC C20, KSIC 20, NACE 20, NAICS 325
- 규제: 화학물질관리법, REACH, US_TSCA, MSDS, OSHA HazCom, KR_OSH
- **수집 목표: 200**
- 핵심 subCategory(차단 시나리오):
  - 위험물 운반·보관 SOP 우회 차단 (`hazmat_transport_sop_bypass`)
  - MSDS 변조·은폐 차단 (`msds_tampering`)
  - 환경 배출 보고 위·변조 차단 (`emission_report_falsify`)
  - 공정 비밀(촉매 비율, 반응 조건) 보호 (`catalyst_ratio_secret`)
  - 임직원 노출 데이터(혈중 농도) PII 보호 (`worker_blood_level_pii`)
- 배포 조합: P1 + P2 + P3 또는 P1 + P3 (식품 미사용 조직)

### Phase 4 — `manufacturing-pharma` (KSIC 21 / ISIC 21)

- ISIC C21, KSIC 21, NACE 21, NAICS 3254
- 규제: 약사법, GMP, US_FDA(21 CFR Part 11), EU_EMA, ICH-GCP, US_HIPAA(임상)
- **수집 목표: 210**
- 핵심 subCategory:
  - 임상시험 피험자 식별(IND/CTA) 보호 (`clinical_subject_id`)
  - 적응증 외 사용(off-label) 권유 차단 (`off_label_promotion`)
  - 부작용·SAE 누락 보고 차단 (`sae_underreport`)
  - 의약품 광고 효능 과장 차단 (`efficacy_exaggeration`)
  - 제조처방·공정 비밀 보호 (rare disease drug 등) (`manufacturing_process_secret`)

### Phase 5 — `manufacturing-automotive` (KSIC 30 / ISIC 29)

- ISIC C29, KSIC 30, NACE 29, NAICS 3361-3363
- 규제: 자동차관리법, 리콜 규정, UNECE WP.29, ISO 26262(Functional Safety), SOTIF
- **수집 목표: 200**
- 핵심 subCategory:
  - 안전 결함 은폐 권유 차단 (`safety_defect_coverup`)
  - 배출가스 조작 권유 차단 (`emission_defeat_device`)
  - 자율주행 책임 회피 권유 차단 (`autonomy_liability_evasion`)
  - 협력사 도면·BOM 비밀 보호 (`supplier_drawing_bom_secret`)

### Phase 6 — `manufacturing-electronics` (KSIC 26 / ISIC 26)

- ISIC C26, KSIC 26, NACE 26, NAICS 334
- 규제: 전기용품안전관리법, KR_RoHS, EU_RoHS, EU_CE, US_FCC, export control(EAR/ITAR)
- **수집 목표: 200**
- 핵심 subCategory:
  - 반도체 공정 레시피 비밀 보호 (`process_recipe_secret`)
  - 수출통제 품목 우회 차단 (`export_control_bypass`)
  - 부품 위조·인증 위반 차단 (`component_counterfeit`)

### Phase 7 — `finance-banking` / `finance-insurance` / `finance-securities-misc` (KSIC 64–66)

- ISIC K, KSIC K, NACE K, NAICS 52
- 규제: 자본시장법, 금융소비자보호법, 전자금융거래법, FATCA, MiFID II, GLBA, AML/KYC
- **수집 목표: 도메인당 200 (3종 합 600)**
- 핵심 subCategory:
  - 투자 권유·확정 수익 표현 차단 (`guaranteed_return_claim`)
  - AML/KYC 우회 권유 차단 (`aml_kyc_bypass`)
  - 시세조종·내부자거래 권유 차단 (`market_manipulation`, `insider_trading`)
  - 보험 약관 설명의무 우회 차단 (`insurance_disclosure_evasion`)

### Phase 8 — `healthcare-clinical` (KSIC 86 / ISIC 86)

- ISIC Q86, KSIC 86, NACE 86, NAICS 621-622
- 규제: 의료법, US_HIPAA, EU_GDPR Art.9, 원격의료 규제, FDA SaMD
- **수집 목표: 220**
- 핵심 subCategory:
  - 진단·처방 직접 안내 차단 (`diagnosis_direct_guidance`)
  - 자살·자해 정보 차단 + 지원 채널 안내 (`self_harm_with_support_channel`)
  - PHI/EMR 보호 (`phi_emr_protect`)
  - 임상 가이드라인 환각 차단 (`clinical_guideline_hallucination`)

### Phase 9 — `public-administration` (KSIC 84 / ISIC 84)

- ISIC O84, KSIC 84, NACE 84, NAICS 92
- 규제: 행정절차법, 정보공개법, 개인정보보호법, 청탁금지법
- **수집 목표: 200**
- 핵심 subCategory: 민원인 PII 보호, 비공개 행정정보 유출 차단, 청탁·금품 권유 차단

### Phase 10+ — 추가 도메인

- `ict-software` (KSIC 62), `ict-info-services` (KSIC 63)
- `retail-stores` (KSIC 47), `retail-wholesale` (KSIC 46)
- `transport-logistics` (KSIC H), `energy-utilities` (KSIC 35)
- `education` (KSIC 85): US_FERPA, KR_PIPA(학생)
- `construction` (KSIC F), `agriculture` (KSIC A)
- **수집 목표: 각 200** (§3 템플릿 적용)

---

## 6. Phase 조합 배포 매트릭스

도메인 키는 직교(orthogonal)하므로, 한 조직이 운영하는 사업 portfolio에 따라 phase를 조합 배포한다.
Compose overlay 1장씩 추가하면 즉시 활성화.

| 조직 유형 | Phase 조합 | 환경 변수 |
| :-- | :-- | :-- |
| 식품 제조 중소기업 | P1 + P2 | `GUARDRAILS_ENABLED_DOMAINS=global,manufacturing-food` |
| 식품 + 화학 복합 그룹 | P1 + P2 + P3 | `global,manufacturing-food,manufacturing-chemical` |
| 제약 기업 | P1 + P4 | `global,manufacturing-pharma` |
| 종합 제조 (자동차+전자) | P1 + P5 + P6 | `global,manufacturing-automotive,manufacturing-electronics` |
| 은행 + 증권 + 보험 | P1 + P7(3종) | `global,finance-banking,finance-insurance,finance-securities-misc` |
| 종합병원 + 보건소 | P1 + P8 | `global,healthcare-clinical` |
| 핀테크 (은행+IT) | P1 + P7 + P10(ict) | `global,finance-banking,ict-software` |
| 공공기관 | P1 + P9 | `global,public-administration` |

**Phase 머지 충돌 해소**: 더 엄격한 action 우선 (`block` > `redact` > `warn` > `allow`), 동률 시 `priority` 큰 쪽 + 더 specific 도메인 우선.
머지 순서: `global → <industry> → <industry-sub> → tenant-override`.

---

## 7. 신규 도메인 추가 / 회수 절차 (데이터 관점)

### 7.1 신규 추가

1. **도메인 키 확정** — ISIC/KSIC division → `<industry>-<sub>[-<function>]`.
2. **`scripts/init-db.sql` 에 도메인 INSERT 추가** — 부모 먼저. `inherits_from` 체인 명시.
   ```sql
   INSERT INTO domains (domain_key, parent_key, display_name, description, regulation_tags, inherits_from)
   VALUES ('manufacturing-chemical', 'manufacturing',
           '{"ko-KR":"제조-화학","en":"Manufacturing - Chemical"}'::jsonb,
           'Chemical manufacturing vertical. Inherits manufacturing > global.',
           ARRAY['KR_CCA','EU_REACH','US_TSCA'], ARRAY['manufacturing','global'])
   ON CONFLICT (domain_key) DO NOTHING;
   ```
   ※ `init-db.sql` 은 **첫 부팅 1회만** 실행. 기존 DB는 별도 migration 또는 Admin/`source='admin'` 경로로 추가.
3. **`scripts/gen-rules.py` 확장** — 도메인 룰 데이터 블록 추가(PRIVACY_INPUT_RULES 패턴 모방), PREFIX는 §1.4 표준 사용. ko-KR/en 두 번들을 동시 emit.
4. **`python3 scripts/gen-rules.py` 실행** → `scripts/<domain>.{kr,en}.json` 생성. `totalRules == rules.length`, ko↔en 미러 검증.
5. **whitelist 작성** — `whitelists/<domain>.<locale>.json` (도메인 일반용어·법령 인용 예외).
6. **테스트 케이스** — 도메인당 input 50 + output 50 = **100케이스**, 정상:edge:우회 = 6:3:1. `test_cases` 테이블 적재.
7. **검증 → 적재** — staging 회귀 통과 후 정책 버전 `active` 승격, Redis 캐시 무효화.

### 7.2 회수 (deprecation)

- `domains` 레지스트리 status `deprecated` 로 변경
- compose overlay 제거 (`GUARDRAILS_ENABLED_DOMAINS` 에서 제외)
- 정책 버전은 `archived` 보존, 신규 평가 시 머지에서 제외

### 7.3 수집 완료 체크리스트 (도메인 단위)

- [ ] `domains` INSERT 추가(부모 선행, `inherits_from` 정확)
- [ ] 룰 ≥ **200개** (§5 목표), `category` 분포가 §3 템플릿 ±허용범위
- [ ] output(`ioType`) 룰 ≥ 30%
- [ ] ko-KR ↔ en 번들 1:1 미러(`totalRules` 동일, subCategory 동일)
- [ ] 전 룰 `examplesPositive`≥1 & `examplesNegative`≥1
- [ ] `patternType` ↔ `patterns` 정합(§2.3)
- [ ] `severity`↔`action`↔`priority` 일관(§2.5–6)
- [ ] `subCategory` 도메인 내 고유
- [ ] `regulationTags` 최소 1개(또는 `[]` 사유 명시)
- [ ] whitelist 작성, 테스트 100+케이스 적재, staging 회귀 green

---

## 8. 부록 — 빠른 검증 스니펫

```bash
# 룰 수 / 미러 / 분포 한눈에
cd MCP-type-Guardrails-Service/scripts
python3 - <<'PY'
import json, collections
for f in ["privacy.kr.json","privacy.en.json",
          "manufacturing-food.kr.json","manufacturing-food.en.json"]:
    d=json.load(open(f)); rs=d["rules"]
    assert d["totalRules"]==len(rs), f"{f}: totalRules mismatch"
    io=collections.Counter(r["ioType"] for r in rs)
    cat=collections.Counter(r["category"] for r in rs)
    miss=[r["ruleId"] for r in rs
          if not r.get("examplesPositive") or not r.get("examplesNegative")]
    print(f, "n=",len(rs), "io=",dict(io), "missing_examples=",len(miss))
    print("   cat=", dict(cat.most_common()))
PY
```

관련 문서: 이 레포 `README.md`(도메인 키↔seed 매핑·기동), `scripts/gen-rules.py`(생성기), `scripts/init-db.sql`(스키마).
