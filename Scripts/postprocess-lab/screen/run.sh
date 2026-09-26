#!/bin/sh
# Screen-term checks against a variant's clean-up sources, on the author's history.
# usage: Scripts/postprocess-lab/screen/run.sh <rules|gate|replace|spell> <variant> [custom words, comma separated]
#   rules    current and 0.85 screen-term gate rules: false fires on real dictations
#            paired with unrelated eval screens (MERGE=4 merges screens to app size)
#   gate     the variant's own soundsLikeScreenTerm (G4 and later) on the same pairs
#   replace  replacements of non-dictionary words by screen terms and custom words
#   spell    NSSpellChecker on names, with and without automatic language detection
# Run Scripts/postprocess-lab/run.sh <variant> <any-name> first: it writes the sources used here.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
TOOL=$1; V=$2
OUT=$ROOT/build/postprocess-lab/screen-$TOOL-$V
mkdir -p "$OUT"
cp "$HERE/$TOOL.swift" "$OUT/main.swift"
if [ "$TOOL" = spell ]; then
  swiftc -O "$OUT/main.swift" -o "$OUT/tool"
  "$OUT/tool"; exit
fi
swiftc -O -enable-bare-slash-regex "$OUT/main.swift" "$ROOT/build/postprocess-lab/src-$V"/TypeMeIt/*.swift -o "$OUT/tool"
"$OUT/tool" "$ROOT/Scripts/cleanup-eval/cases.json" "$HOME/Library/Application Support/TypeMeIt/history.json" ${3:+"$3"}
