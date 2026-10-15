# racko_llm — model servers for the Racko chatbot

Self-hosted models for Racko's website assistant, on one **RTX 3060 / 3060 Ti (8 GB)**. All servers are
[llama.cpp](https://github.com/ggml-org/llama.cpp) `llama-server` with OpenAI-compatible APIs; core-api
(in the Racko repo) calls them and does all the RAG work. **No Racko data is stored here.**

```
core-api (Proxmox VM) ──HTTPS──▶ Cloudflare (Access: service token required) ──tunnel──▶ cloudflared ─▶ chat / embed / rerank
                                  https://llm.racko.ai                          (outbound-only from this machine)
```

| Service | Local port | Public path on `https://llm.racko.ai` | Model |
|---|---|---|---|
| chat | 8080 | `/v1/chat/completions` (default route) | Qwen3-8B Q4_K_M (Profile A) · Qwen3-4B-Instruct-2507 Q4_K_M (Profile B) |
| embed | 8081 | `/v1/embeddings` | Qwen3-Embedding-0.6B Q8_0 |
| rerank | 8082 | `/v1/rerank` | bge-reranker-v2-m3 Q8_0 |
| cloudflared | — | — | Cloudflare Tunnel connector (profile `tunnel`) |
| docling *(optional)* | 5001 | not published | docling-serve — best run on the app server instead (see below) |
| gpu-exporter *(optional)* | 9835 | not published | GPU memory, temperature, utilisation |

## What makes this production-ready

| Concern | How it's handled |
|---|---|
| Reachability | Cloudflare Tunnel: this machine only makes **outbound** connections — no port forwarding, works behind the office router |
| Who can call it | **Cloudflare Access** service token checked at Cloudflare's edge (others never reach this machine) **+** llama.cpp API key |
| Encryption | HTTPS to Cloudflare, tunnel to this machine; servers listen on `127.0.0.1` only |
| Reproducible software | Images pinned by tag **and** digest (llama.cpp v0.6.0 = b11429, cloudflared 2026.10.0, docling-serve v1.36.0) |
| Reproducible models | `models.lock` pins file, Hugging Face commit, size and SHA-256; servers load local files only |
| Secrets | `secrets/llm_api_key` and `secrets/cloudflared_credentials.json` are Docker secrets — not in `.env`, the command line or `docker inspect`; the Cloudflare account certificate is deleted after setup |
| Liveness / updates | Health checks; `deploy.sh` preflight → update → verify models → health → smoke test → **automatic rollback** |
| Resources / disk | CPU/RAM caps on CPU services; log rotation (5 × 20 MB per container) |
| Observability | llama.cpp `/metrics`, cloudflared metrics, optional GPU exporter |
| Licences | Models Apache-2.0 (`models.lock`); llama.cpp, docling MIT; cloudflared Apache-2.0 |

**Known limits:** one GPU = single point of failure; it answers four chats at a time in Profile B (production),
one in Profile A (`CHAT_PARALLEL`), and further requests queue. Chat falls back to OpenAI and search to keyword-only
in core-api. Cloudflare closes responses that take **> 100 s** — fine for chat (~15 s)
and search, but **not for parsing big PDFs**, which is why docling belongs on the app server.
This is an **office desktop**: keep it powered on, disable sleep, and keep other GPU apps closed.

## Choose a profile

| | Profile A | Profile B (default, production) |
|---|---|---|
| Chat model | Qwen3-8B | Qwen3-4B-Instruct-2507 |
| Reranker on | CPU (+1–3 s per question) | GPU |
| Chats answered at once | 1 (`CHAT_PARALLEL=1`, `CHAT_CTX=6144`) | 4 (`CHAT_PARALLEL=4`, `CHAT_CTX=24576`) |
| VRAM (approx.) | ~6.9 GB | ~5.8 GB (estimate; check `nvidia-smi`) |
| Answers | Good | Good — Qwen's published scores for 4B-Instruct-2507 match 8B (non-thinking) on instruction following and beat it on most others; slightly weaker in non-English; ~2× faster |

With a desktop session running (~300–700 MB of VRAM), use `CHAT_CTX=6144` for A, or choose B.
`CHAT_CTX` is shared by the slots: keep `CHAT_CTX ≥ CHAT_PARALLEL × 6144`, the size of one chatbot request.
After switching profiles, set `CHATBOT_SELFHOSTED_CHAT_MODEL` in the chatbot's `.env` to the new `CHAT_MODEL_ALIAS`.

---

## First-time setup

### 1. Machine

```bash
nvidia-smi                                  # GPU visible, note memory
sudo nvidia-smi -pm 1                       # persistence mode for 24/7 serving
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target   # never sleep
```

### 2. Docker + NVIDIA Container Toolkit

```bash
curl -fsSL https://get.docker.com | sudo sh && sudo usermod -aG docker $USER && newgrp docker
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo mkdir -p /etc/cdi && sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
sudo systemctl restart docker
docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi    # must print the GPU
```

The `WARN … not found` lines from `cdi generate` (Vulkan, imex, fabricmanager) are harmless.

### 3. Get the code and configure

```bash
git clone https://github.com/gisul-ecosystem/racko_llm.git ~/racko_llm && cd ~/racko_llm
cp env.example .env && chmod 600 .env       # defaults: BIND_ADDR=127.0.0.1, Profile A, no tunnel yet
mkdir -p secrets && chmod 700 secrets
openssl rand -hex 32 > secrets/llm_api_key && chmod 600 secrets/llm_api_key
```

### 4. Deploy the models and test them on this machine

```bash
./deploy.sh --no-pull     # downloads ~6 GB of models (SHA-256 verified), starts, health-checks, smoke-tests
```

All smoke-test lines must say `ok`. Close GPU-heavy desktop apps first (browser, VS Code): with Qwen3-8B the
three servers plus a desktop session use ~7.3 of 8.2 GB.

### 5. Cloudflare Tunnel and Access (once)

**a. Tunnel — one command here, one click by a Cloudflare admin.**

```bash
./tunnel-setup.sh
```

It prints a Cloudflare login link. Someone with access to the **racko.ai** Cloudflare account opens it, signs in,
selects **racko.ai** and clicks **Authorize**. The script then creates the tunnel `racko-llm-gpu`, the DNS record
`llm.racko.ai`, saves the tunnel's own credentials to `secrets/cloudflared_credentials.json`, writes
`CLOUDFLARED_TUNNEL_ID` to `.env`, and **deletes the account certificate** it received (the running tunnel never
needs it). The routes (`/v1/embeddings` → embed, `/v1/rerank` → rerank, everything else → chat) are in
[`cloudflared/config.yml`](cloudflared/config.yml), versioned here — no dashboard routes to click.

**b. Access (lock it down) — Cloudflare dashboard, by the same admin.** Zero Trust → Access → Service credentials →
**Service tokens** → Create `racko-core-api` → copy **Client ID** and **Client Secret** (shown once; they go into
core-api's `.env`, not here). Then Access → Applications → **Add** → Self-hosted → domain `llm.racko.ai` → one policy:
Action **Service Auth**, Include **Service Token = racko-core-api**, no other Allow policies. Without this the models
would be reachable from the internet behind only the API key.

**c. Bot protection** — make sure Bot Fight Mode / WAF challenges don't apply to `llm.racko.ai`
(server-to-server calls can't solve challenges). The public smoke test detects this.

**d. Turn the tunnel on and test it end to end**

```bash
sed -i 's/^COMPOSE_PROFILES=.*/COMPOSE_PROFILES=rerank-cpu,tunnel/' .env
./deploy.sh --no-pull
CF_ACCESS_CLIENT_ID=<id> CF_ACCESS_CLIENT_SECRET=<secret> ./smoke-test.sh --public
```

The public test calls `https://llm.racko.ai` exactly like core-api, and checks that Cloudflare blocks callers
**without** the service token and the servers block callers without the API key. All lines must say `ok`.

### 6. Point core-api at it

In core-api's `.env` (Proxmox VM; for local development, your own `core-api/.env`), then restart core-api:

```env
CHATBOT_SELFHOSTED_API_KEY=<contents of secrets/llm_api_key>
CHATBOT_SELFHOSTED_CF_ACCESS_CLIENT_ID=<Access service token Client ID>
CHATBOT_SELFHOSTED_CF_ACCESS_CLIENT_SECRET=<Access service token Client Secret>

CHATBOT_CHAT_PRIMARY=selfhosted
CHATBOT_CHAT_FALLBACK=openai                    # or none
CHATBOT_SELFHOSTED_CHAT_URL=https://llm.racko.ai/v1
CHATBOT_SELFHOSTED_CHAT_MODEL=qwen3-8b          # = CHAT_MODEL_ALIAS

CHATBOT_EMBED_PROVIDER=selfhosted
CHATBOT_SELFHOSTED_EMBED_URL=https://llm.racko.ai/v1
CHATBOT_SELFHOSTED_EMBED_MODEL=qwen3-embedding-0.6b
CHATBOT_EMBED_QUERY_INSTRUCTION=Given a question from a visitor to the Racko website, retrieve passages that answer it

CHATBOT_RERANK_PROVIDER=selfhosted
CHATBOT_RERANK_API=cohere                       # llama.cpp /v1/rerank format
CHATBOT_SELFHOSTED_RERANK_URL=https://llm.racko.ai/v1
CHATBOT_SELFHOSTED_RERANK_MODEL=bge-reranker-v2-m3

CHATBOT_OPENAI_API_KEY=                         # chat fallback
CHATBOT_OPENAI_CHAT_MODEL=
CHATBOT_LLM_TIMEOUT_MS=60000
```

Super Admin → Knowledge Base → **Status** must show every model *Configured* and "via Cloudflare Tunnel + Access".

### Document parser (docling)

Run it **next to core-api on the app server**, not here: it needs only CPU, and parsing large PDFs can take longer
than Cloudflare's 100-second limit. Use the `docling` service definition from this compose file there, and set
`DOCLING_URL=http://<app-server>:5001` + `DOCLING_API_KEY` in core-api. (The `docling` profile here remains for
LAN-only setups.)

### Without the tunnel (LAN / WireGuard only)

Remove `tunnel` from `COMPOSE_PROFILES`, set `BIND_ADDR` to the LAN or WireGuard IP, firewall ports 8080–8082 to
the core-api host (`sudo ufw allow from <ip> to any port 8080:8082 proto tcp`), and use `http://<BIND_ADDR>:8080/v1`
(8081, 8082) in core-api with no CF_ACCESS variables.

---

## Operations

```bash
./deploy.sh                       # update to latest main (auto-rollback on failure)
./deploy.sh --no-pull             # apply .env changes
./smoke-test.sh                   # local checks (+ cloudflared connected)
./fetch-models.sh --verify        # re-check model files against models.lock
docker compose ps; docker compose logs --tail=100 chat; docker compose logs --tail=50 cloudflared
nvidia-smi
```

**Upgrades** are code changes: edit an image tag + digest in `docker-compose.yml` or add a line to `models.lock`,
commit, then `./deploy.sh` on the machine. Changing the **embedding** model also needs *Reindex all* in the console.
`.env` isn't versioned, so `deploy.sh` can't roll it back — keep a copy before editing.

**Rotating credentials**: API key — new `secrets/llm_api_key`, `./deploy.sh --no-pull`, update core-api. Access token —
create a new service token in Cloudflare, add it to the policy, update core-api, then delete the old one.
Tunnel credentials — delete the tunnel in Cloudflare (Networks → Tunnels), remove `secrets/cloudflared_credentials.json`, run `./tunnel-setup.sh` again, `./deploy.sh --no-pull`.

### Monitoring and alerts

| Target | Alert when |
|---|---|
| `http://127.0.0.1:8080/metrics` (and 8081, 8082) — scrape locally | target down > 2 min; `llamacpp:requests_deferred` stays > 3 |
| Cloudflare → tunnel status | tunnel *Down* / *Degraded* (Cloudflare can email on this) |
| `http://127.0.0.1:9835/metrics` (profile `monitoring`) | GPU memory > 95 %; temperature > 83 °C for 10 min |
| core-api Knowledge Base status | any model not configured; documents needing reindex |

Minimum without Prometheus: a cron elsewhere running the `--public` smoke test every 5 minutes.

### Troubleshooting

| Symptom | Fix |
|---|---|
| `deploy.sh`: `chmod 644 secrets/cloudflared_credentials.json` | cloudflared runs non-root; keep `secrets/` at 700 |
| `tunnel-setup.sh`: could not create the tunnel | a tunnel named `racko-llm-gpu` already exists — delete it in Cloudflare or run `TUNNEL_NAME=<new> ./tunnel-setup.sh` |
| smoke test: `cloudflared has no registered tunnel connection` | wrong/expired token, or outbound HTTPS/7844 blocked — `docker compose logs cloudflared` |
| `--public`: chat works but embeddings/rerank return chat errors | rule order in `cloudflared/config.yml`: specific paths must come before the catch-all |
| Web UI at https://llm.racko.ai can't chat | enter the API key (`secrets/llm_api_key`) in the UI's settings; share it only with the team |
| `--public`: `blocked by Cloudflare` / 403 HTML | Access policy or service token wrong, or a bot/WAF challenge on `llm.racko.ai` |
| core-api: `blocked by Cloudflare (302)` | `CHATBOT_SELFHOSTED_CF_ACCESS_*` missing or not in the Access policy |
| chat unhealthy, `out of memory` / `cudaMalloc failed` | close GPU apps, `CHAT_CTX=6144`, or Profile B → `./deploy.sh --no-pull` |
| `fetch-models.sh` MISMATCH | corrupted download — run again; if it repeats, don't edit the hash, investigate |
| Smoke test warns `<think>` | harmless (core-api strips it); newer llama.cpp image fixes it |
