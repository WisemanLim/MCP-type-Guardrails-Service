# MCP-type Guardrails Service — Operating

루트는 운영(배포·구성·통합) 전용. 컴포넌트 소스는 형제 디렉토리.

```
../Guardrails-Service-Server                    # MCP Server (NestJS, TS)
../Guardrails-Service-Policy-Engine             # Policy Engine (NestJS, TS) + 정책 번들
../Guardrails-Service-Audit-Service             # Audit Service (NestJS, TS)
../../DA(Python,R,...)/Guardrails-Service-Detection-Engine   # Detection Engine (Python, FastAPI)
```

## 빠른 시작

```bash
cp .env.example .env
make up-p1            # Phase 1 (privacy) 단독 기동
make smoke            # 헬스/판정 검증
make logs             # 로그 확인
make down             # 종료
```

`http://localhost:8080` 가 MCP HTTP transport, `/health`, `/mcp/tools/<name>` 노출.

## 단계적 배포

| 단계 | 도메인 | 명령 |
| :-- | :-- | :-- |
| P1 | `global` (privacy) | `make up-p1` |
| P1 + P2 | `global` + `manufacturing-food` | `make up-p1-p2` *(P2 번들 추가 후)* |
| P1 + P3 | `global` + `<P3 도메인>` | `docker compose -f docker-compose.yml -f docker-compose.privacy.yml -f docker-compose.<p3>.yml up -d` |

각 phase는 overlay 한 장으로 합쳐지며, 코어 `docker-compose.yml`은 phase 간 변경 없음.

## 컴포넌트 독립 구동

각 컴포넌트는 자체 `Dockerfile`과 `package.json` / `pyproject.toml` 보유. 로컬 dev:

```bash
# Detection Engine
cd ../../DA\(Python,R,...\)/Guardrails-Service-Detection-Engine
pip install -e .
uvicorn src.main:app --port 8081

# Policy Engine
cd ../Guardrails-Service-Policy-Engine
npm install && npm run start:dev

# Audit Service
cd ../Guardrails-Service-Audit-Service
npm install && npm run start:dev

# MCP Server
cd ../Guardrails-Service-Server
npm install && npm run start:dev
```

## MCP 클라이언트 연결

stdio 모드:

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

원격 SSE:

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
