#!/bin/sh
# Scores S1-mini with and without the edit on the clean-up eval, both as Q8_0
# GGUF built the same way, through the A2S1 variant (llama-server on :8091).
# usage: Scripts/postprocess-lab/s1-words/eval.sh
# needs: llama-server on PATH, python3 with torch, transformers, huggingface_hub, gguf
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
B=$ROOT/build/s1-words
mkdir -p "$B"
[ -d "$B/llama.cpp" ] || git clone -q --depth 1 https://github.com/ggml-org/llama.cpp "$B/llama.cpp"
[ -d "$B/original" ] || python3 -c "from huggingface_hub import snapshot_download as s; s('superwhisper/s1-mini', revision='88f6b15896c73bbb13a3b596e0afe8ea0d5150b4', local_dir='$B/original')"
[ -d "$B/words" ] || python3 "$HERE/edit.py" "$B/words"
for m in original words; do
  [ -f "$B/$m.gguf" ] || python3 "$B/llama.cpp/convert_hf_to_gguf.py" "$B/$m" --outtype q8_0 --outfile "$B/$m.gguf"
  llama-server -m "$B/$m.gguf" --port 8091 --host 127.0.0.1 -ngl 99 --ctx-size 4096 --jinja --no-webui > "$B/$m.server.log" 2>&1 &
  PID=$!
  until curl -s http://127.0.0.1:8091/health | grep -q ok; do
    sleep 1
    kill -0 $PID 2>/dev/null || { echo "server died"; tail -5 "$B/$m.server.log"; exit 1; }
  done
  "$ROOT/Scripts/postprocess-lab/run.sh" A2S1 "s1-$m"
  kill $PID; wait $PID 2>/dev/null || true
done
