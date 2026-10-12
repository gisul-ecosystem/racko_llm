#!/usr/bin/env bash
# Checks every running server answers the exact calls core-api makes, and rejects calls without the key.
# Usage: ./smoke-test.sh [host]    (default: BIND_ADDR from .env)
set -euo pipefail
cd "$(dirname "$0")"

env_value() { grep -E "^$1=" .env | tail -1 | cut -d= -f2- | tr -d '"' | tr -d "'"; }
HOST="${1:-$(env_value BIND_ADDR)}"
PROFILES=",$(env_value COMPOSE_PROFILES),"
KEY="$(tr -d '[:space:]' < secrets/llm_api_key 2>/dev/null || true)"
[ -n "$KEY" ] || { echo "secrets/llm_api_key is missing or empty"; exit 1; }
fail=0

check() {
  local name="$1" url="$2" body="$3" expect="$4" warn="${5:-}"
  local started out ms
  started=$(date +%s%N)
  if out=$(curl -sS --max-time 120 -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" "$url" -d "$body"); then
    ms=$(( ($(date +%s%N) - started) / 1000000 ))
    if ! echo "$out" | grep -q "$expect"; then
      echo "FAIL $name — unexpected response: ${out:0:300}"; fail=1
    elif [ -n "$warn" ] && echo "$out" | grep -q "$warn"; then
      echo "warn $name (${ms} ms) — response contains $warn (core-api strips it; update llama.cpp)"
    else
      echo "ok   $name (${ms} ms)"
    fi
  else
    echo "FAIL $name — no response from $url"; fail=1
  fi
}

for port in 8080 8081 8082; do
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://$HOST:$port/health" || true)
  [ "$code" = "200" ] && echo "ok   health :$port" || { echo "FAIL health :$port -> $code"; fail=1; }
done

check "chat" "http://$HOST:8080/v1/chat/completions" \
  '{"model":"chat","messages":[{"role":"user","content":"In one sentence: what is a VPS?"}],"max_tokens":80,"chat_template_kwargs":{"enable_thinking":false}}' \
  '"content"' '<think>'

check "embeddings" "http://$HOST:8081/v1/embeddings" \
  '{"model":"embed","input":["Racko GPU cloud in Mumbai","Dedicated EPYC servers"]}' \
  '"embedding"'

check "rerank" "http://$HOST:8082/v1/rerank" \
  '{"model":"rerank","query":"GPU servers price","documents":["VPS plans start at 1,499 per month","GPU cloud A100 hourly pricing"]}' \
  '"relevance_score"'

for port in 8080 8081 8082; do
  code=$(curl -s -o /dev/null -w '%{http_code}' -H "Content-Type: application/json" \
    "http://$HOST:$port/v1/embeddings" -d '{"input":"x"}')
  [ "$code" = "401" ] && echo "ok   :$port rejects calls without the key" || { echo "FAIL :$port without key -> $code (expected 401)"; fail=1; }
done

if [[ "$PROFILES" == *",docling,"* ]]; then
  DKEY="$(env_value DOCLING_API_KEY)"
  printf '# Racko\n\nTest document.\n' > /tmp/racko-smoke.md
  code=$(curl -s -o /tmp/racko-docling.json -w '%{http_code}' -H "X-Api-Key: $DKEY" \
    -F "files=@/tmp/racko-smoke.md;type=text/markdown" -F "to_formats=md" "http://$HOST:5001/v1/convert/file")
  if [ "$code" = "200" ] && grep -q md_content /tmp/racko-docling.json; then echo "ok   docling convert"; else echo "FAIL docling convert -> $code"; fail=1; fi
  code=$(curl -s -o /dev/null -w '%{http_code}' -F "files=@/tmp/racko-smoke.md" "http://$HOST:5001/v1/convert/file")
  [ "$code" = "401" ] || [ "$code" = "403" ] && echo "ok   docling rejects calls without the key" || { echo "FAIL docling without key -> $code"; fail=1; }
fi

echo
command -v nvidia-smi >/dev/null && nvidia-smi --query-gpu=name,memory.used,memory.total,temperature.gpu --format=csv || true
exit $fail
