#!/usr/bin/env bash
# Safe (re)deploy: preflight → update code → verify models → start → wait healthy → smoke test.
# If anything after the update fails, it rolls back to the previous commit and restarts that.
#
#   ./deploy.sh             pull origin/main, then deploy
#   ./deploy.sh --no-pull   redeploy the current checkout (e.g. after editing .env)
set -euo pipefail
cd "$(dirname "$0")"

HEALTH_TIMEOUT_S="${HEALTH_TIMEOUT_S:-900}"
log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { log "ERROR: $*"; exit 1; }
env_value() { grep -E "^$1=" .env | tail -1 | cut -d= -f2- | tr -d '"' | tr -d "'"; }

# ── Preflight: refuse to start an unsafe or broken configuration ─────────────────────────────
[ -f .env ] || die ".env missing — cp env.example .env"
[ "$(stat -c %a .env)" = "600" ] || log "warn: .env is readable by others — chmod 600 .env"
[ -s secrets/llm_api_key ] || die "secrets/llm_api_key missing — see README step 3"
[ "$(tr -d '[:space:]' < secrets/llm_api_key | wc -c)" -ge 32 ] || die "secrets/llm_api_key is too short (use openssl rand -hex 32)"
[ "$(stat -c %a secrets/llm_api_key)" = "600" ] || log "warn: chmod 600 secrets/llm_api_key"

BIND_ADDR="$(env_value BIND_ADDR)"
[ -n "$BIND_ADDR" ] || die "BIND_ADDR is empty in .env"
if [ "$BIND_ADDR" = "0.0.0.0" ] && [ "${ALLOW_ALL_INTERFACES:-0}" != "1" ]; then
  die "BIND_ADDR=0.0.0.0 exposes the models on every interface (Docker bypasses ufw). Use the private/WireGuard IP, or ALLOW_ALL_INTERFACES=1 if this machine has no public interface."
fi
# Note: never `cmd | grep -q` under pipefail — grep exits on the first match, the writer gets SIGPIPE (141)
# and the pipeline "fails" even though it matched. Capture first, then grep the variable.
HOST_ADDRS="$(ip -o addr show 2>/dev/null || true)"
grep -qwF "$BIND_ADDR" <<<"$HOST_ADDRS" || [ "$BIND_ADDR" = "0.0.0.0" ] || die "BIND_ADDR $BIND_ADDR is not an address of this machine"

PROFILES=",$(env_value COMPOSE_PROFILES),"
if [[ "$PROFILES" == *",docling,"* ]]; then
  [ "$(env_value DOCLING_API_KEY | wc -c)" -gt 32 ] || die "docling profile is on but DOCLING_API_KEY is empty/short — without it the parser accepts anyone"
fi
[[ "$PROFILES" == *",rerank-cpu,"* || "$PROFILES" == *",rerank-gpu,"* ]] || die "COMPOSE_PROFILES must include rerank-cpu or rerank-gpu"
if [[ "$PROFILES" == *",tunnel,"* ]]; then
  [ -s secrets/cloudflared_token ] || die "tunnel profile is on but secrets/cloudflared_token is missing — see README (Cloudflare Tunnel)"
  # cloudflared runs as a non-root user inside its container, so the file must be readable;
  # the secrets/ directory itself stays 700, which keeps other users on this machine out.
  [ "$(stat -c %a secrets/cloudflared_token)" = "644" ] || die "chmod 644 secrets/cloudflared_token (secrets/ stays chmod 700)"
  [ "$(stat -c %a secrets)" = "700" ] || log "warn: chmod 700 secrets"
  [ "$BIND_ADDR" = "127.0.0.1" ] || log "warn: with the tunnel, BIND_ADDR=127.0.0.1 keeps the servers off the office network entirely"
fi

command -v nvidia-smi >/dev/null && nvidia-smi >/dev/null || die "nvidia-smi failed — GPU driver not working"
docker compose version >/dev/null || die "docker compose plugin missing"

# ── Helpers ───────────────────────────────────────────────────────────────────────────────────
start() {
  ./fetch-models.sh || return 1
  docker compose pull --quiet || return 1
  docker compose up -d --remove-orphans || return 1
}

wait_healthy() {
  local deadline=$(( $(date +%s) + HEALTH_TIMEOUT_S )) pending
  log "waiting for health checks (up to ${HEALTH_TIMEOUT_S}s; first start loads models into VRAM)…"
  while :; do
    # Services without a health check (gpu-exporter) only need to be running.
    pending="$(docker compose ps --format '{{.Service}} {{.State}} {{.Health}}' | awk '$2!="running" || ($3!="" && $3!="healthy")')"
    [ -z "$pending" ] && { log "all services healthy"; return 0; }
    if grep -qE ' (unhealthy|exited|dead|restarting)' <<<"$pending"; then
      log "unhealthy: $pending"; docker compose logs --tail=40 >&2 || true; return 1
    fi
    [ "$(date +%s)" -lt "$deadline" ] || { log "timed out: $pending"; return 1; }
    sleep 10
  done
}

# ── Update ──────────────────────────────────────────────────────────────────────────────────
prev="$(git rev-parse HEAD)"
if [ "${1:-}" != "--no-pull" ]; then
  git diff --quiet && git diff --cached --quiet || die "local changes in tracked files — commit or discard them first"
  git fetch --quiet origin
  git merge --ff-only --quiet origin/main || die "cannot fast-forward to origin/main"
fi
new="$(git rev-parse HEAD)"
log "deploying $(git log -1 --format='%h %s' "$new")"

if start && wait_healthy && ./smoke-test.sh; then
  log "DEPLOYED $new"
  exit 0
fi

# ── Roll back ───────────────────────────────────────────────────────────────────────────────
log "deploy of $new FAILED"
if [ "$new" != "$prev" ]; then
  log "rolling back to $(git log -1 --format='%h %s' "$prev")"
  git reset --hard --quiet "$prev"
  if start && wait_healthy && ./smoke-test.sh; then
    log "ROLLED BACK to $prev — investigate $new before retrying"
  else
    log "ROLLBACK ALSO FAILED — check: docker compose logs; nvidia-smi"
  fi
else
  log "nothing to roll back to (same commit). If you changed .env, revert it and run ./deploy.sh --no-pull"
fi
exit 1
