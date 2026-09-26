#!/bin/sh
# Scores one variant of the clean-up sources on the eval, with per-case timing.
# usage: Scripts/postprocess-lab/run.sh <baseline|variant> <out-name> [cases.json]
# A variant is variants/<name>.patch applied to a copy of TypeMeIt's clean-up
# sources; output goes to build/postprocess-lab/out/<out-name>.
# Environment: EVAL_MODE=cold|prewarm, EVAL_PREWARM_MS, EVAL_SKIP_BLIND=1,
# EVAL_GATE_PUNCT=0|1, EVAL_LOG_GATE=1, EVAL_NO_MODEL=1, EVAL_PUNCT_MAP=<json>.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
V=$1; NAME=$2; CASES=${3:-$ROOT/Scripts/cleanup-eval/cases.json}
WORK=$ROOT/build/postprocess-lab/src-$V
OUT=$ROOT/build/postprocess-lab/out/$NAME
rm -rf "$WORK"; mkdir -p "$WORK/TypeMeIt" "$OUT"
for f in PostProcessor LocalCleanup WritingStyle Digits ModelText CustomWordMatcher ScreenContext Log; do cp "$ROOT/TypeMeIt/$f.swift" "$WORK/TypeMeIt/"; done
[ "$V" = baseline ] || (cd "$WORK" && patch -s -p1 < "$HERE/variants/$V.patch")
swiftc -parse-as-library -O -enable-bare-slash-regex "$HERE/runner/eval.swift" "$WORK"/TypeMeIt/*.swift -o "$OUT/eval"
cp "$CASES" "$OUT/cases.json"
EVAL_CASES="$OUT/cases.json" EVAL_OUT="$OUT" "$OUT/eval" > "$OUT/log.txt" 2>&1 || true
tail -5 "$OUT/log.txt"
