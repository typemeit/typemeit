#!/bin/sh
# Scores the shipped meeting summary and title on cases.json: the app's
# MeetingSummary compiled in, run against Apple Intelligence. Needs macOS 26
# with Apple Intelligence on.
set -e
cd "$(dirname "$0")"
swiftc -parse-as-library -O eval.swift ../../TypeMeIt/Meetings/MeetingSummary.swift ../../TypeMeIt/Log.swift -o eval
./eval
