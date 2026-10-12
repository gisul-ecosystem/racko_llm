#!/usr/bin/env bash
# Downloads the model files selected in .env from Hugging Face at the exact revisions in models.lock,
# and verifies size + SHA-256. Servers then load local files only — startup never depends on the internet.
#
#   ./fetch-models.sh            download missing files for the models selected in .env, verify all
#   ./fetch-models.sh --verify   only verify (no downloads); exit 1 on any mismatch
#   ./fetch-models.sh --all      download every file in models.lock
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-}"
MODELS_DIR="./models"
mkdir -p "$MODELS_DIR"

[ -f .env ] || { echo "Missing .env (cp env.example .env)"; exit 1; }
env_value() { grep -E "^$1=" .env | tail -1 | cut -d= -f2- | tr -d '"' | tr -d "'"; }
HF_TOKEN="$(env_value HF_TOKEN || true)"

if [ "$MODE" = "--all" ]; then
  mapfile -t WANTED < <(grep -vE '^\s*(#|$)' models.lock | cut -f1)
else
  WANTED=("$(env_value CHAT_MODEL_FILE)" "$(env_value EMBED_MODEL_FILE)" "$(env_value RERANK_MODEL_FILE)")
  mapfile -t WANTED < <(printf '%s\n' "${WANTED[@]}" | awk '!seen[$0]++')
fi

fail=0
for file in "${WANTED[@]}"; do
  [ -n "$file" ] || { echo "FAIL a *_MODEL_FILE is empty in .env"; fail=1; continue; }
  line="$(awk -F'\t' -v f="$file" '$1==f' models.lock)"
  [ -n "$line" ] || { echo "FAIL $file is not in models.lock — only pinned files may be used"; fail=1; continue; }
  IFS=$'\t' read -r _ repo rev size sha license <<<"$line"
  path="$MODELS_DIR/$file"

  if [ ! -f "$path" ] || [ "$(stat -c%s "$path")" != "$size" ]; then
    if [ "$MODE" = "--verify" ]; then echo "FAIL $file missing or incomplete"; fail=1; continue; fi
    echo "get  $file ($((size / 1024 / 1024)) MB) from $repo@${rev:0:8}"
    auth=(); [ -n "$HF_TOKEN" ] && auth=(-H "Authorization: Bearer $HF_TOKEN")
    # Write to .part so a half file is never loaded; -C - resumes an interrupted download.
    # A file at least as large as expected but wrong (corrupt/tampered) can't be resumed: start over.
    [ -f "$path" ] && mv "$path" "$path.part"
    if [ -f "$path.part" ] && [ "$(stat -c%s "$path.part")" -ge "$size" ]; then rm -f "$path.part"; fi
    curl -fL --progress-bar --retry 5 --retry-delay 10 -C - "${auth[@]}" -o "$path.part" \
      "https://huggingface.co/$repo/resolve/$rev/$file"
    mv "$path.part" "$path"
  fi

  echo -n "sha  $file ... "
  actual="$(sha256sum "$path" | cut -d' ' -f1)"
  if [ "$actual" = "$sha" ]; then
    echo "ok ($license)"
  else
    echo "MISMATCH (got $actual) — deleting"; rm -f "$path"; fail=1
  fi
done
exit $fail
