#!/bin/sh
# Scores the shipped clean-up path on cases.json: the app's PostProcessor
# compiled in, run against Apple Intelligence. Needs macOS 26 with Apple
# Intelligence on. An optional argument names another PostProcessor.swift.
set -e
cd "$(dirname "$0")"
PP="${1:-../../typemeit/PostProcessor.swift}"
swiftc -parse-as-library -O -enable-bare-slash-regex eval.swift "$PP" ../../typemeit/Log.swift ../../typemeit/ModelText.swift ../../typemeit/ScreenContext.swift ../../typemeit/CustomWordMatcher.swift ../../typemeit/LocalCleanup.swift -o eval
./eval
