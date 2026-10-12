#!/usr/bin/env bash
# Checks all three model servers answer the exact calls core-api makes.
# Usage: ./smoke-test.sh [host]   (default: localhost; reads LLM_API_KEY from .env)
set -euo pipefail
cd "$(dirname "$0")"

HOST="${1:-localhost}"
KEY="$(grep -E '^LLM_API_KEY=' .env | cut -d= -f2-)"
[ -n "$KEY" ] || { echo "LLM_API_KEY is empty in .env"; exit 1; }
AUTH=(-H "Authorization: Bearer $KEY" -H "Content-Type: application/json")
fail=0

check() {
  local name="$1" url="$2" body="$3" expect="$4"
  local started out
  started=$(date +%s%N)
  if out=$(curl -sS --max-time 120 "${AUTH[@]}" "$url" -d "$body"); then
    local ms=$(( ($(date +%s%N) - started) / 1000000 ))
    if echo "$out" | grep -q "$expect"; then
      echo "ok   $name (${ms} ms)"
    else
      echo "FAIL $name — unexpected response: ${out:0:300}"; fail=1
    fi
  else
    echo "FAIL $name — no response from $url"; fail=1
  fi
}

for port in 8080 8081 8082; do
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://$HOST:$port/health" || true)
  echo "health :$port -> $code"
done

check "chat (no <think> output expected)" "http://$HOST:8080/v1/chat/completions" \
  '{"model":"qwen3","messages":[{"role":"user","content":"In one sentence: what is a VPS?"}],"max_tokens":80,"chat_template_kwargs":{"enable_thinking":false}}' \
  '"content"'

check "embeddings" "http://$HOST:8081/v1/embeddings" \
  '{"model":"embed","input":["Racko GPU cloud in Mumbai","Dedicated EPYC servers"]}' \
  '"embedding"'

check "rerank" "http://$HOST:8082/v1/rerank" \
  '{"model":"rerank","query":"GPU servers price","documents":["VPS plans start at 1,499 per month","GPU cloud A100 hourly pricing"]}' \
  '"relevance_score"'

code=$(curl -s -o /dev/null -w '%{http_code}' -H "Content-Type: application/json" "http://$HOST:8080/v1/chat/completions" -d '{"messages":[{"role":"user","content":"hi"}],"max_tokens":1}')
if [ "$code" = "401" ]; then echo "ok   requests without the key are rejected"; else echo "FAIL unauthenticated request got $code (expected 401)"; fail=1; fi

echo
command -v nvidia-smi >/dev/null && nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv
exit $fail
