# Racko chatbot models — RTX 3060 (8 GB) machine

Runs the three self-hosted models the chatbot uses, all with OpenAI-compatible APIs (llama.cpp `llama-server`):

| Service | Port | Endpoint core-api calls | Model |
|---|---|---|---|
| chat | 8080 | `/v1/chat/completions` | Qwen3-8B Q4_K_M (Profile A) or Qwen3-4B-Instruct-2507 (Profile B) |
| embed | 8081 | `/v1/embeddings` | Qwen3-Embedding-0.6B Q8_0 |
| rerank | 8082 | `/v1/rerank` | bge-reranker-v2-m3 Q8_0 |
| docling *(optional)* | 5001 | `/v1/convert/file` | Document parser for PDF / Word / PowerPoint uploads |

## Which profile

| | Profile A (default) | Profile B |
|---|---|---|
| Chat model | Qwen3-8B | Qwen3-4B-Instruct-2507 |
| Reranker runs on | CPU (adds ~1–3 s per question) | GPU |
| VRAM used (approx.) | ~6.9 GB | ~5.2 GB |
| Answer quality | Better | Good, ~2× faster |

Start with A. If `nvidia-smi` shows the card full or the chat container crashes with out-of-memory, lower `CHAT_CTX` to `6144` or switch to B.
The card serves **one answer at a time**; others queue. core-api falls back to OpenAI when this machine is slow or down (`CHATBOT_CHAT_FALLBACK=openai`).

## 1. Check the machine

```bash
nvidia-smi        # expect "NVIDIA GeForce RTX 3060" and ~8 GB (some 3060s have 12 GB — more headroom)
free -h           # 16 GB RAM recommended; with 8 GB RAM leave docling off this machine
df -h             # ~15 GB free for model files
```

Nothing else should use the GPU (no desktop session/other models) — every MB counts on 8 GB.

## 2. Install Docker + NVIDIA Container Toolkit (Ubuntu)

```bash
curl -fsSL https://get.docker.com | sh
# NVIDIA Container Toolkit: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html
sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker
docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi   # must print the GPU
```

## 3. Configure and start

```bash
cd racko-llm    # this folder, copied to the GPU machine
cp env.example .env
openssl rand -hex 32          # paste into LLM_API_KEY in .env
nano .env                      # set BIND_ADDR to this machine's private IP; choose profile
docker compose up -d
docker compose logs -f chat    # first start downloads ~5 GB of models; wait for "server is listening"
./smoke-test.sh                # all lines must say ok
```

## 4. Lock it down

Only core-api may reach these ports. They are protected by `LLM_API_KEY`, but also firewall them:

```bash
sudo ufw allow from <CORE_API_SERVER_IP> to any port 8080:8082 proto tcp
sudo ufw allow from <CORE_API_SERVER_IP> to any port 5001 proto tcp   # only if docling runs here
sudo ufw enable
```

> Docker publishes ports through iptables and can bypass ufw. Setting `BIND_ADDR` to the private LAN IP
> (not `0.0.0.0`) keeps the ports off public interfaces. If core-api reaches this machine over the public
> internet, put the ports behind a TLS reverse proxy or a VPN (WireGuard/Tailscale) instead.

## 5. Point core-api at it

Add to `/opt/racko/core-api/.env` on the app server (replace `<GPU_IP>` and the key), then restart core-api:

```env
CHATBOT_CHAT_PRIMARY=selfhosted
CHATBOT_CHAT_FALLBACK=openai            # or none
CHATBOT_SELFHOSTED_API_KEY=<LLM_API_KEY from the GPU machine .env>

CHATBOT_SELFHOSTED_CHAT_URL=http://<GPU_IP>:8080/v1
CHATBOT_SELFHOSTED_CHAT_MODEL=qwen3-8b                     # = CHAT_MODEL_ALIAS

CHATBOT_EMBED_PROVIDER=selfhosted
CHATBOT_SELFHOSTED_EMBED_URL=http://<GPU_IP>:8081/v1
CHATBOT_SELFHOSTED_EMBED_MODEL=qwen3-embedding-0.6b        # = EMBED_MODEL_ALIAS
CHATBOT_EMBED_QUERY_INSTRUCTION=Given a question from a visitor to the Racko website, retrieve passages that answer it

CHATBOT_RERANK_PROVIDER=selfhosted
CHATBOT_RERANK_API=cohere                                  # llama.cpp's /v1/rerank format
CHATBOT_SELFHOSTED_RERANK_URL=http://<GPU_IP>:8082/v1
CHATBOT_SELFHOSTED_RERANK_MODEL=bge-reranker-v2-m3

# OpenAI fallback for chat (only used when the GPU machine fails or times out)
CHATBOT_OPENAI_API_KEY=
CHATBOT_OPENAI_CHAT_MODEL=
CHATBOT_LLM_TIMEOUT_MS=60000

DOCLING_URL=http://<GPU_IP>:5001                           # only if docling runs here
```

Then in the Super Admin console (or `GET /api/v1/super-admin/chatbot/status`) every provider should show `configured: true`.

**Embeddings have no OpenAI fallback on purpose**: vectors from different models can't be mixed. If this machine is
down, search automatically drops to keyword-only until it's back. Changing `EMBED_MODEL` later means
**Reindex all** in the console.

## Operations

```bash
docker compose ps                         # all running?
docker compose logs --tail=100 chat
curl -s http://localhost:8080/metrics     # Prometheus metrics (tokens/s, queue)
nvidia-smi                                # VRAM in use
docker compose pull && docker compose up -d   # update llama.cpp
```

After the first working setup, pin `LLAMA_CUDA_IMAGE` / `LLAMA_CPU_IMAGE` in `.env` to the exact build tag you tested.

| Symptom | Fix |
|---|---|
| `chat` restarts, log shows `out of memory` / `cudaMalloc failed` | `CHAT_CTX=6144`, or Profile B |
| Answers slow (>20 s) | Profile B; check nothing else uses the GPU |
| `smoke-test.sh` chat output contains `<think>` | Update the image; core-api strips it anyway |
| `401` from core-api calls | `CHATBOT_SELFHOSTED_API_KEY` ≠ `LLM_API_KEY` |
| Models re-download on every restart | Check the `models` volume exists: `docker volume ls` |
