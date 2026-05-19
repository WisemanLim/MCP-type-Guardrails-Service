#!/usr/bin/env bash
set -euo pipefail

MCP_URL="${MCP_URL:-http://localhost:8080}"
API_KEY="${GUARDRAILS_API_KEY:-dev-key-please-change}"

say() { printf "\n\033[1;36m== %s ==\033[0m\n" "$1"; }

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
