# MCP-type-Guardrails-Service/ — 루트 디렉토리 개요 / Root Directory Abstract

> [← INDEX.md](INDEX.md)

## 파일 목록 / File List

| 파일 / File | LOC | 역할 / Role | 리뷰 링크 / Review |
|---|---|---|---|
| Makefile | 273 | 모든 운영 진입점 (`up-*` / `down-*` / `smoke` / `logs` …) | [Makefile.md](Makefile.md) |
| .env.example | 38 | 전 서비스 공통 환경 변수 템플릿 | [.env.example.md](.env.example.md) |
| docker-compose.yml | 182 | base — Postgres, Redis, MCP, Policy, Detection, Audit | [docker-compose.yml.md](docker-compose.yml.md) |
| docker-compose.privacy.yml | 26 | Phase 1 overlay: `global` 도메인 + privacy JSON 마운트 | [docker-compose.privacy.yml.md](docker-compose.privacy.yml.md) |
| docker-compose.food.yml | 28 | Phase 2 overlay: `manufacturing-food` (STUB) | [docker-compose.food.yml.md](docker-compose.food.yml.md) |
| docker-compose.local.yml | 53 | SQLite 모드: postgres/redis 비활성 | [docker-compose.local.yml.md](docker-compose.local.yml.md) |
| docker-compose.admin.yml | 59 | admin-service 추가 | [docker-compose.admin.yml.md](docker-compose.admin.yml.md) |
| docker-compose.admin-local.yml | 27 | admin × local 결합 시 sqlite 강제 | [docker-compose.admin-local.yml.md](docker-compose.admin-local.yml.md) |
| docker-compose.admin-standalone.yml | 96 | admin 독립 호스트 배포 (자체 network/db) | [docker-compose.admin-standalone.yml.md](docker-compose.admin-standalone.yml.md) |
| docker-compose.admin-web.yml | 42 | admin-web (Next.js) overlay | [docker-compose.admin-web.yml.md](docker-compose.admin-web.yml.md) |

## 디렉토리 구조 요약 / Structure Summary

루트는 **오케스트레이션 전용** 디렉토리이다. 실제 서비스 코드(MCP Server, Policy Engine, Detection Engine, Audit Service, Admin, Admin-Web)는 형제 디렉토리에 분리되어 있고, 본 루트는 그 빌드/조합/시드/스모크/배포만 담당한다.

설계의 핵심 두 축:

1. **Makefile + Compose overlay 매트릭스** — `phases × suffixes` 조합으로 `up-p1`, `up-p1-admin`, `up-p1-admin-web-local`, `up-p1-p2-admin-web-local` 등 5×2+6=대량의 타깃을 자동 생성. 변경 시 `PHASES`/`SUFFIXES` 변수 한 곳만 늘리면 됨.
2. **`scripts/`** — 컨테이너 부팅 시 자동으로 마운트되는 *데이터 시드* (정책 JSON, Postgres DDL) 와 운영자 손작업용 스모크 스크립트.

`local.yml` 의 `depends_on: !reset []` 는 **합성 순서 의존**이다. Makefile 라인 18–19 주석에서 명시되며, 깨지면 `admin-local`/`p1-local` 같은 타깃이 부팅하지 못한다.

## 주요 의존 관계 / Key Dependencies

- **내부 호출 그래프 없음** — 모든 “호출”은 컨테이너 간 HTTP (`POLICY_ENGINE_URL` 등 env).
- **외부 디렉토리 의존**: `../Guardrails-Service-{Server,Policy-Engine,Audit-Service,Admin,Admin-Web}`, `../../DA(Python,R,...)/Guardrails-Service-Detection-Engine`. 본 루트는 그 디렉토리들이 *동일 부모 트리*에 존재한다고 가정 (compose `build.context` 상대 경로).
- **시스템 도구**: `docker`, `docker compose`, `make`, `bash`, `python3`, `curl`, `jq`.

## 위험 신호 / Risk Signals

- **하드코딩된 기본 비밀 (`.env.example`)**: `change-me-in-prod`, `dev-key-please-change`. 운영 배포 시 *서비스 측 fail-fast*가 없으면 그대로 통과.
- **`build.context` 상대 경로 결합도**: 워크스페이스 폴더 구조 가정이 깊다(특수문자 포함 `(Python,R,...)` 디렉토리 이름).
- **`gen-rules.py` 의 비표준 액션 매핑**(`non_std_map`)이 *조용히* 동작 — 데이터 측 오타가 무시될 위험. Step 4.3 #1 참조.
