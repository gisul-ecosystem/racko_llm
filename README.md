# racko_llm — model servers for the Racko chatbot

Self-hosted models for Racko's website assistant, on one **RTX 3060 (8 GB)**. All servers are
[llama.cpp](https://github.com/ggml-org/llama.cpp) `llama-server` with OpenAI-compatible APIs; core-api
(in the Racko repo) calls them and does all the RAG work. **No Racko data is stored here.**

| Service | Port | Endpoint | Model |
|---|---|---|---|
| chat | 8080 | `/v1/chat/completions` | Qwen3-8B Q4_K_M (Profile A) · Qwen3-4B-Instruct-2507 Q4_K_M (Profile B) |
| embed | 8081 | `/v1/embeddings` | Qwen3-Embedding-0.6B Q8_0 |
| rerank | 8082 | `/v1/rerank` | bge-reranker-v2-m3 Q8_0 |
| docling *(optional)* | 5001 | `/v1/convert/file` | docling-serve — PDF / Word / PowerPoint parsing |
| gpu-exporter *(optional)* | 9835 | `/metrics` | GPU memory, temperature, utilisation |

## What makes this production-ready

| Concern | How it's handled |
|---|---|
| Reproducible software | Images pinned by tag **and** digest (llama.cpp v0.6.0 = b11429, docling-serve v1.36.0) |
| Reproducible models | `models.lock` pins file, Hugging Face commit, size and SHA-256; `fetch-models.sh` refuses anything else. Servers load local files — startup never needs the internet |
| Secrets | Model API key in `secrets/llm_api_key` (Docker secret, `--api-key-file`) — not in `.env`, the command line or `docker inspect`. Docling has its own key (`X-Api-Key`) |
| Network exposure | Ports bind only to `BIND_ADDR` (private/WireGuard IP). `deploy.sh` refuses `0.0.0.0` and IPs not on this machine |
| Liveness | Health checks on every server; `deploy.sh` waits for all to be healthy |
| Safe updates | `deploy.sh`: preflight → pull → verify models → start → health → smoke test → **automatic rollback** on failure |
| Resource isolation | CPU/RAM caps on the CPU reranker and docling so they can't starve the chat server |
| Disk | Docker log rotation (5 × 20 MB per container) |
| Observability | llama.cpp `/metrics` on every server + optional GPU exporter (Prometheus format) |
| Licences | All models Apache-2.0 (listed in `models.lock`); llama.cpp, docling MIT |

**Known limits (by design, covered in core-api):** one GPU = single point of failure and one answer at a time.
Chat falls back to OpenAI when this machine is slow or down; search falls back to keyword-only (embeddings
can't fall back — vectors from different models don't mix).

## Choose a profile

| | Profile A (default) | Profile B |
|---|---|---|
| Chat model | Qwen3-8B | Qwen3-4B-Instruct-2507 |
| Reranker on | CPU (+1–3 s per question) | GPU |
| VRAM (approx.) | ~6.9 GB | ~5.2 GB |
| Answers | Better | Good, ~2× faster |

Start with A. If the chat container runs out of memory, set `CHAT_CTX=6144` or switch to B (both are in `env.example`).

---

## First-time setup

### 1. Machine

Ubuntu 22.04/24.04 LTS, NVIDIA driver installed, ~20 GB free disk, 16 GB RAM recommended
(with 8 GB RAM run docling on another machine).

```bash
nvidia-smi                     # RTX 3060 visible; note total memory (8 GB or 12 GB)
sudo nvidia-smi -pm 1          # persistence mode: keeps the driver loaded, stabler for 24/7 serving
sudo apt-mark hold 'nvidia-driver-*'   # stop unattended upgrades changing the driver under running containers
```

Hardening: SSH keys only (`PasswordAuthentication no`), `unattended-upgrades` for security patches, Docker enabled at boot.

### 2. Docker + NVIDIA Container Toolkit

```bash
curl -fsSL https://get.docker.com | sh
# https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html
sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker
sudo systemctl enable docker
docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi   # must show the GPU
```

### 3. Network — how core-api reaches this machine

Pick one; it sets `BIND_ADDR`:

| core-api and this machine are… | Do this | `BIND_ADDR` |
|---|---|---|
| on the same private network / VLAN | firewall the ports to the core-api server only | this machine's private IP |
| in different places **(recommended: WireGuard)** | join both to WireGuard | this machine's WireGuard IP (e.g. `10.8.0.5`) |
| reachable only over the internet | TLS reverse proxy (Caddy/nginx) in front; never expose 8080–8082 directly | `127.0.0.1` + proxy |

Docker publishes ports through iptables and **bypasses ufw**, so binding to the right IP is the real control. Also:

```bash
sudo ufw allow from <CORE_API_IP> to any port 8080:8082 proto tcp
sudo ufw allow from <CORE_API_IP> to any port 5001 proto tcp     # if docling runs here
```

### 4. Configure

```bash
git clone https://github.com/gisul-ecosystem/racko_llm.git && cd racko_llm
cp env.example .env && chmod 600 .env
nano .env                                   # BIND_ADDR, profile, optional docling/monitoring
mkdir -p secrets && chmod 700 secrets
openssl rand -hex 32 > secrets/llm_api_key && chmod 600 secrets/llm_api_key
# if docling is enabled: put the output of `openssl rand -hex 32` into DOCLING_API_KEY in .env
```

### 5. Deploy

```bash
./deploy.sh --no-pull      # first run downloads ~6 GB of models, verifies SHA-256, starts, health-checks, smoke-tests
```

Every line of the smoke test must say `ok`. Keep the output — it shows timings and VRAM use.

### 6. Point core-api at it

In `/opt/racko/core-api/.env` on the app server (replace `<BIND_ADDR>` and keys), then restart core-api:

```env
CHATBOT_CHAT_PRIMARY=selfhosted
CHATBOT_CHAT_FALLBACK=openai                    # or none
CHATBOT_SELFHOSTED_API_KEY=<contents of secrets/llm_api_key>

CHATBOT_SELFHOSTED_CHAT_URL=http://<BIND_ADDR>:8080/v1
CHATBOT_SELFHOSTED_CHAT_MODEL=qwen3-8b          # = CHAT_MODEL_ALIAS

CHATBOT_EMBED_PROVIDER=selfhosted
CHATBOT_SELFHOSTED_EMBED_URL=http://<BIND_ADDR>:8081/v1
CHATBOT_SELFHOSTED_EMBED_MODEL=qwen3-embedding-0.6b
CHATBOT_EMBED_QUERY_INSTRUCTION=Given a question from a visitor to the Racko website, retrieve passages that answer it

CHATBOT_RERANK_PROVIDER=selfhosted
CHATBOT_RERANK_API=cohere                       # llama.cpp /v1/rerank format
CHATBOT_SELFHOSTED_RERANK_URL=http://<BIND_ADDR>:8082/v1
CHATBOT_SELFHOSTED_RERANK_MODEL=bge-reranker-v2-m3

CHATBOT_OPENAI_API_KEY=                         # chat fallback
CHATBOT_OPENAI_CHAT_MODEL=
CHATBOT_LLM_TIMEOUT_MS=60000

DOCLING_URL=http://<BIND_ADDR>:5001             # only if docling runs here
DOCLING_API_KEY=<DOCLING_API_KEY from .env>
```

Check: Super Admin → Knowledge Base status (or `GET /api/v1/super-admin/chatbot/status`) shows every provider `configured: true`.

---

## Operations

```bash
./deploy.sh                    # update to latest main (auto-rollback on failure)
./deploy.sh --no-pull          # apply .env changes
./smoke-test.sh                # check everything now
./fetch-models.sh --verify     # re-check model files against models.lock
docker compose ps              # state + health
docker compose logs --tail=100 chat
nvidia-smi                     # VRAM / temperature
```

**Upgrading llama.cpp or a model** is a code change, reviewed like any other: edit the image tag + digest in
`docker-compose.yml`, or add a line to `models.lock` and point `*_MODEL_FILE` at it → commit → `./deploy.sh`
on the machine. Changing the **embedding** model also needs *Reindex all* in the Super Admin console.
`.env` changes are not versioned, so `deploy.sh` can't roll them back — keep a copy before editing.

### Monitoring and alerts

Scrape with your Prometheus (or any agent that reads Prometheus format):

| Target | Alert when |
|---|---|
| `http://<BIND_ADDR>:8080/metrics` (and 8081, 8082) | target down > 2 min; `llamacpp:requests_deferred` (queue) stays > 3 |
| `http://<BIND_ADDR>:9835/metrics` (profile `monitoring`) | GPU memory > 95 %; temperature > 83 °C for 10 min |
| core-api chatbot status | any provider `configured: false`; documents needing reindex |

Without Prometheus, the minimum is a cron on another machine running `./smoke-test.sh <BIND_ADDR>` every 5 minutes and alerting on a non-zero exit.

### Troubleshooting

| Symptom | Fix |
|---|---|
| `deploy.sh`: BIND_ADDR is not an address of this machine | Wrong IP, or WireGuard not up yet (`wg show`) |
| chat unhealthy, logs `out of memory` / `cudaMalloc failed` | `CHAT_CTX=6144` or Profile B, then `./deploy.sh --no-pull` |
| Slow answers (> 20 s) | Profile B; make sure nothing else uses the GPU |
| core-api gets `401` | `CHATBOT_SELFHOSTED_API_KEY` ≠ `secrets/llm_api_key` |
| `fetch-models.sh` MISMATCH | Corrupted download — run it again. If it repeats, the upstream file changed: don't edit the hash, investigate |
| Smoke test warns `<think>` | Harmless (core-api strips it); a newer llama.cpp image fixes it |
