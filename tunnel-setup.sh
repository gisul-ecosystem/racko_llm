#!/usr/bin/env bash
# One-time Cloudflare Tunnel setup for https://llm.racko.ai (locally-managed tunnel).
#
#   ./tunnel-setup.sh
#
# 1. Prints a Cloudflare login link. Someone with access to the racko.ai Cloudflare account opens it,
#    selects racko.ai and clicks Authorize. (This machine receives a temporary account certificate.)
# 2. Creates the tunnel "racko-llm-gpu" and its DNS record llm.racko.ai.
# 3. Saves only the tunnel's own credentials to secrets/, writes CLOUDFLARED_TUNNEL_ID to .env,
#    and DELETES the account certificate — the running tunnel never needs it.
#
# Routes are in cloudflared/config.yml. Cloudflare Access (service token + policy) is set up separately
# in the dashboard — see README "Cloudflare Access". Uses the pinned cloudflared image; nothing is
# installed on this machine.
set -euo pipefail
cd "$(dirname "$0")"

TUNNEL_NAME="${TUNNEL_NAME:-racko-llm-gpu}"
HOSTNAME_PUBLIC="${HOSTNAME_PUBLIC:-llm.racko.ai}"
IMAGE="cloudflare/cloudflared:2026.10.0@sha256:9b49eed8f62806d5d45ddf59ecefb5710429598ea6d3fcccd2af938f621b2b07"
WORK="$(pwd)/.cloudflared-setup"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { log "ERROR: $*"; exit 1; }
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

[ -f .env ] || die ".env missing — cp env.example .env first"
if [ -s secrets/cloudflared_credentials.json ]; then
  die "secrets/cloudflared_credentials.json already exists — the tunnel is set up. Delete it first to start over."
fi
mkdir -p secrets "$WORK" && chmod 700 secrets "$WORK"

cf() {
  # Run as the current user so files written to $WORK belong to us, with HOME pointing at $WORK.
  docker run --rm -i --user "$(id -u):$(id -g)" -e HOME=/work -v "$WORK:/work/.cloudflared" "$IMAGE" "$@"
}

log "Step 1/3 — Cloudflare login. Open the link below in a browser, sign in to the account that owns"
log "racko.ai, choose racko.ai and click Authorize. This window continues by itself afterwards."
cf tunnel login
[ -s "$WORK/cert.pem" ] || die "login did not complete (no certificate received)"

log "Step 2/3 — creating tunnel '$TUNNEL_NAME'"
if ! cf tunnel create "$TUNNEL_NAME"; then
  die "could not create the tunnel. If '$TUNNEL_NAME' already exists in Cloudflare, delete it there (Networks → Tunnels) or run with TUNNEL_NAME=<new name>."
fi
creds="$(ls "$WORK"/*.json 2>/dev/null | head -1 || true)"
[ -n "$creds" ] || die "tunnel created but no credentials file was written"
TUNNEL_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["TunnelID"])' "$creds")"
log "tunnel id: $TUNNEL_ID"

log "Step 3/3 — pointing $HOSTNAME_PUBLIC at the tunnel"
if ! cf tunnel route dns "$TUNNEL_NAME" "$HOSTNAME_PUBLIC"; then
  log "warn: DNS route failed — if a record for $HOSTNAME_PUBLIC already exists, change it in Cloudflare DNS to a"
  log "      proxied CNAME → $TUNNEL_ID.cfargotunnel.com"
fi

# Keep only the tunnel's own credentials. cloudflared runs as a non-root user in its container,
# so the file must be readable; secrets/ stays 700 to keep other users of this machine out.
cp "$creds" secrets/cloudflared_credentials.json
chmod 644 secrets/cloudflared_credentials.json

if grep -qE '^CLOUDFLARED_TUNNEL_ID=' .env; then
  sed -i "s/^CLOUDFLARED_TUNNEL_ID=.*/CLOUDFLARED_TUNNEL_ID=$TUNNEL_ID/" .env
else
  printf '\nCLOUDFLARED_TUNNEL_ID=%s\n' "$TUNNEL_ID" >> .env
fi

# The account certificate in $WORK is removed by the EXIT trap.
log "Done. Saved secrets/cloudflared_credentials.json and CLOUDFLARED_TUNNEL_ID in .env;"
log "deleted the account certificate."
log "Next: Cloudflare Access in the dashboard (README), then add 'tunnel' to COMPOSE_PROFILES and ./deploy.sh --no-pull"
