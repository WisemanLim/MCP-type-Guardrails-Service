# docker-compose.admin-web.yml — 코드 리뷰 / Code Review

> 리뷰 레벨 / Review Level: 2
> [← INDEX.md](INDEX.md)

## 파일 요약 / File Summary

- 역할 / Role: Admin Web (Next.js 14) overlay — *브라우저가 직접* host port 통해 admin-service 호출. 컨테이너 ↔ 컨테이너 reachability 불필요.
- 진입점에서의 거리: **1** (admin.yml or admin-standalone.yml 과 함께).
- 라인 수: 42.
- 주요 export: `admin-web` 서비스. 호스트 포트 3001.

## 라인 단위 분석 / Line-by-Line Analysis

```yaml path=docker-compose.admin-web.yml lines=1-42
# Admin Web (Next.js console) overlay. Pairs with docker-compose.admin.yml.
#
# Default deployment does NOT include this overlay.
# ...
services:
  admin-web:
    build:
      context: ../Guardrails-Service-Admin-Web
      dockerfile: Dockerfile
      args:
        NEXT_PUBLIC_ADMIN_API_BASE_URL: ${ADMIN_WEB_API_BASE_URL:-http://localhost:8084}
    container_name: gr-admin-web
    restart: unless-stopped
    environment:
      NODE_ENV: ${NODE_ENV:-production}
      PORT: 3001
      NEXT_PUBLIC_ADMIN_API_BASE_URL: ${ADMIN_WEB_API_BASE_URL:-http://localhost:8084}
    ports:
      - "${ADMIN_WEB_EXPOSED_PORT:-3001}:3001"
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://127.0.0.1:3001/login"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 10s
    # No `networks:` — admin-web serves static / SSR HTML to the user's
    # browser; the browser then calls the Admin API directly via the host
    # port (NEXT_PUBLIC_ADMIN_API_BASE_URL). This means admin-web does not
    # need container-to-container reachability to admin-service, and can
    # safely overlay on either the main stack or the standalone stack.
```

**분석 / Analysis (Level 2)**

- `build.args.NEXT_PUBLIC_ADMIN_API_BASE_URL` — Next.js 의 `NEXT_PUBLIC_*` 환경변수는 *빌드 타임*에 클라이언트 번들에 박힌다. 따라서 *환경변수가 build args 로도 전달*되어야 함. 이중 정의(build args + environment) — Dockerfile에서 동시에 사용해 SSR(server-side) + CSR(client-side) 양쪽 처리.
- `healthcheck`: `wget -qO-` 사용. `wget` 이 *Alpine base* (Node.js docker 이미지)에서 사용 가능한지 확인 필요 — 일반적으로 `node:alpine`은 `wget` 미포함이지만 별도 설치되어 있을 수 있음. 만약 미설치면 healthcheck 무한 실패.
- `/login` 경로를 ping — Next.js 페이지가 정상 SSR 되는지 검증. `/health` 라우트를 따로 만들지 않은 *실용주의*.
- `# No networks:` — 가장 중요한 *설계 결정*. 사용자 브라우저가 *호스트*에서 admin-web (3001) + admin-service (8084) 두 호스트 포트에 동시에 붙는다. 두 컨테이너가 *같은 docker 네트워크에 있을 필요가 없다*.

**짚어볼 점 / Watch-outs**

- `NEXT_PUBLIC_ADMIN_API_BASE_URL=http://localhost:8084` — *클라이언트(브라우저) 입장의 localhost*. 사용자의 PC에서 *원격 호스트*로 접속할 땐 `localhost` 가 아닌 *그 호스트의 IP/도메인* 이 와야 함. 운영 배포 시 반드시 override.
- `wget` healthcheck 의존 — 이미지 dependancy. Dockerfile에 `wget` 설치 가드 권고.
- `restart: unless-stopped` + healthcheck 실패 시 silent 재시작. Next.js 빌드 깨짐을 운영자가 logs 봐야 알 수 있음.
- `args` 와 `environment` 양쪽에 같은 키를 박는 패턴은 *Dockerfile에서 두 번 export* 가 정확히 되어야 의도대로 작동. 형제 Dockerfile 확인 필요.

## 파일 수준 평가 / File-Level Verdict

- 강점 / Strengths:
  1. *네트워크 분리 명확* — admin-web이 main / standalone 어디에 얹혀도 동작.
  2. build args + env 이중 처리로 SSR/CSR 양쪽 안전.
  3. healthcheck path 가 *실제 사용자 entry point*(`/login`)라 *유의미한 점검*.
- 위험 / Risks:
  1. `NEXT_PUBLIC_ADMIN_API_BASE_URL` 의 *localhost* default 가 운영 배포 시 *문제 시그널*.
  2. `wget` 이미지 의존 — 미설치 시 silent unhealthy.
- 개선 권고 / Recommendations:
  1. *production NODE_ENV* 에서 default url `localhost`이면 빌드 자체를 *경고/거부*.
  2. healthcheck 를 `node -e "fetch('http://127.0.0.1:3001/login')…"` 또는 `/api/health` 라우트로 표준화.
- 재읽기 권고 레벨: **2**.
