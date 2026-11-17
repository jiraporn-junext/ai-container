#!/usr/bin/env bash
# Waits for the local Ollama server to accept requests and makes sure the
# configured model is in the store, so the container is usable straight away.
set -uo pipefail

MODEL="${OLLAMA_MODEL:-qwen3:1.7b}"
# The API port follows OLLAMA_HOST unless OLLAMA_PORT says otherwise
HOSTPORT="${OLLAMA_HOST:-0.0.0.0:11434}"
PORT="${OLLAMA_PORT:-${HOSTPORT##*:}}"
API="http://127.0.0.1:${PORT}"

log() { printf '[ollama-bootstrap] %s\n' "$*"; }

model_present() {
  curl -sf "${API}/api/tags" 2>/dev/null | grep -Fq "\"${MODEL}\""
}

log "waiting for ollama server on ${API}"
for ((i = 0; i < 120; i++)); do
  if curl -sf "${API}/api/version" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! curl -sf "${API}/api/version" >/dev/null 2>&1; then
  log "ERROR: ollama server never became ready, cannot fetch ${MODEL}"
  exit 1
fi

if model_present; then
  log "model ${MODEL} is already present"
  exit 0
fi

log "pulling ${MODEL} - first run downloads the weights and takes a few minutes"
if OLLAMA_HOST="127.0.0.1:${PORT}" ollama pull "${MODEL}"; then
  log "model ${MODEL} is ready"
else
  log "ERROR: failed to pull ${MODEL} - check network access and retry with 'make pull'"
  exit 1
fi
