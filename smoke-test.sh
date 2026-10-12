#!/usr/bin/env bash
# Checks the servers answer the exact calls core-api makes, and reject callers without credentials.
#
#   ./smoke-test.sh            local: http://BIND_ADDR:8080-8082 (and :5001 with the docling profile)
#   ./smoke-test.sh --public   through the Cloudflare Tunnel at LLM_PUBLIC_URL, exactly as core-api calls it.
#                              Needs the Access service token core-api uses, passed for this run only:
#                              CF_ACCESS_CLIENT_ID=… CF_ACCESS_CLIENT_SECRET=… ./smoke-test.sh --public
set -euo pipefail
cd "$(dirname "$0")"

env_value() { grep -E "^$1=" .env | tail -1 | cut -d= -f2- | tr -d '"' | tr -d "'"; }
MODE="${1:-local}"
PROFILES=",$(env_value COMPOSE_PROFILES),"
KEY="$(tr -d '[:space:]' < secrets/llm_api_key 2>/dev/null || true)"
[ -n "$KEY" ] || { echo "secrets/llm_api_key is missing or empty"; exit 1; }
fail=0

if [ "$MODE" = "--public" ]; then
  BASE="$(env_value LLM_PUBLIC_URL)"; BASE="${BASE%/}"
  [ -n "$BASE" ] || { echo "Set LLM_PUBLIC_URL in .env (e.g. https://llm.racko.ai)"; exit 1; }
  [ -n "${CF_ACCESS_CLIENT_ID:-}" ] && [ -n "${CF_ACCESS_CLIENT_SECRET:-}" ] \
    || { echo "Pass CF_ACCESS_CLIENT_ID and CF_ACCESS_CLIENT_SECRET (the Access service token core-api uses)"; exit 1; }
  ACCESS=(-H "CF-Access-Client-Id: $CF_ACCESS_CLIENT_ID" -H "CF-Access-Client-Secret: $CF_ACCESS_CLIENT_SECRET")
  url() { echo "$BASE$2"; }        # one hostname; the tunnel routes by path
else
  HOST="$(env_value BIND_ADDR)"
  ACCESS=()
  url() { echo "http://$HOST:$1$2"; }
fi

check() {
  local name="$1" target="$2" body="$3" expect="$4" warn="${5:-}"
  local started out ms
  started=$(date +%s%N)
  if out=$(curl -sS --max-time 120 "${ACCESS[@]}" -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" "$target" -d "$body"); then
    ms=$(( ($(date +%s%N) - started) / 1000000 ))
    if ! echo "$out" | grep -q "$expect"; then
      echo "FAIL $name — unexpected response: ${out:0:300}"; fail=1
    elif [ -n "$warn" ] && echo "$out" | grep -q "$warn"; then
      echo "warn $name (${ms} ms) — response contains $warn (core-api strips it; update llama.cpp)"
    else
      echo "ok   $name (${ms} ms)"
    fi
  else
    echo "FAIL $name — no response from $target"; fail=1
  fi
}

expect_blocked() {
  local name="$1" code="$2"; shift 2
  if [[ " $* " == *" $code "* ]]; then echo "ok   $name ($code)"; else echo "FAIL $name -> $code (expected one of: $*)"; fail=1; fi
}

echo "== ${MODE#--} checks"
if [ "$MODE" != "--public" ]; then
  for port in 8080 8081 8082; do
    code=$(curl -s -o /dev/null -w '%{http_code}' "$(url $port /health)" || true)
    [ "$code" = "200" ] && echo "ok   health :$port" || { echo "FAIL health :$port -> $code"; fail=1; }
  done
fi

check "chat" "$(url 8080 /v1/chat/completions)" \
  '{"model":"chat","messages":[{"role":"user","content":"In one sentence: what is a VPS?"}],"max_tokens":80,"chat_template_kwargs":{"enable_thinking":false}}' \
  '"content"' '<think>'

check "embeddings" "$(url 8081 /v1/embeddings)" \
  '{"model":"embed","input":["Racko GPU cloud in Mumbai","Dedicated EPYC servers"]}' \
  '"embedding"'

check "rerank" "$(url 8082 /v1/rerank)" \
  '{"model":"rerank","query":"GPU servers price","documents":["VPS plans start at 1,499 per month","GPU cloud A100 hourly pricing"]}' \
  '"relevance_score"'

# Without the model API key: every server must refuse.
for target in "8080 /v1/chat/completions" "8081 /v1/embeddings" "8082 /v1/rerank"; do
  set -- $target
  code=$(curl -s -o /dev/null -w '%{http_code}' "${ACCESS[@]}" -H "Content-Type: application/json" "$(url "$1" "$2")" -d '{"input":"x","messages":[{"role":"user","content":"x"}]}')
  expect_blocked "$2 rejects calls without the API key" "$code" 401
done

if [ "$MODE" = "--public" ]; then
  # Without the Access service token Cloudflare must stop the request before it reaches this machine.
  code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
    "$(url 0 /v1/embeddings)" -d '{"input":"x"}')
  expect_blocked "Cloudflare Access blocks callers without the service token" "$code" 401 403 302
fi

if [[ "$PROFILES" == *",docling,"* ]] && [ "$MODE" != "--public" ]; then
  DKEY="$(env_value DOCLING_API_KEY)"
  printf '# Racko\n\nTest document.\n' > /tmp/racko-smoke.md
  code=$(curl -s -o /tmp/racko-docling.json -w '%{http_code}' -H "X-Api-Key: $DKEY" \
    -F "files=@/tmp/racko-smoke.md;type=text/markdown" -F "to_formats=md" "$(url 5001 /v1/convert/file)")
  if [ "$code" = "200" ] && grep -q md_content /tmp/racko-docling.json; then echo "ok   docling convert"; else echo "FAIL docling convert -> $code"; fail=1; fi
  code=$(curl -s -o /dev/null -w '%{http_code}' -F "files=@/tmp/racko-smoke.md" "$(url 5001 /v1/convert/file)")
  expect_blocked "docling rejects calls without the key" "$code" 401 403
fi

if [[ "$PROFILES" == *",tunnel,"* ]] && [ "$MODE" != "--public" ]; then
  if docker compose logs --tail=200 cloudflared 2>/dev/null | grep -q "Registered tunnel connection"; then
    echo "ok   cloudflared connected to Cloudflare"
  else
    echo "FAIL cloudflared has no registered tunnel connection (docker compose logs cloudflared)"; fail=1
  fi
fi

echo
command -v nvidia-smi >/dev/null && nvidia-smi --query-gpu=name,memory.used,memory.total,temperature.gpu --format=csv || true
exit $fail
