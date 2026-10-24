#!/bin/sh
# Serves one GGUF with llama-server on :8092 (Metal) and runs the eval through the
# GL variant, which sends the Apple model's prompt to this server instead; then
# stops the server.
# usage: Scripts/postprocess-lab/llm/eval-model.sh <model.gguf> <out-name> [extra llama-server args]
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
MODEL=$1; NAME=$2; shift 2
LOG=$ROOT/build/postprocess-lab/$NAME.server.log
mkdir -p "$ROOT/build/postprocess-lab"
llama-server -m "$MODEL" --port 8092 --host 127.0.0.1 -ngl 99 --ctx-size 8192 --jinja --no-webui --parallel 1 --cache-reuse 256 "$@" > "$LOG" 2>&1 &
PID=$!
until curl -s http://127.0.0.1:8092/health | grep -q ok; do
  sleep 1
  kill -0 $PID 2>/dev/null || { echo "server died"; tail -5 "$LOG"; exit 1; }
done
curl -s http://127.0.0.1:8092/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"hi"}],"max_tokens":5,"chat_template_kwargs":{"enable_thinking":false}}' > /dev/null
EVAL_MODE=cold EVAL_GATE_PUNCT=1 "$ROOT/Scripts/postprocess-lab/run.sh" GL "$NAME"
kill $PID; wait $PID 2>/dev/null
