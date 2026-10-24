#!/bin/sh
# usage: run.sh <words.json> <mic.wav> <others.wav>
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
APP="$HERE/../../../TypeMeIt"
for f in Meetings/EchoFold Meetings/EchoLag Meetings/EchoBleedDetector ModelText; do cp "$APP/$f.swift" "$HERE/Sources/echofold/"; done
swift build -c release --package-path "$HERE" --scratch-path "$HERE/../../../build/asr-eval-echofold" >&2
"$HERE/../../../build/asr-eval-echofold/release/echofold" "$@"
