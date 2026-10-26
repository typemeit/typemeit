#!/bin/sh
# Scores the shipped meeting folder suggestion on cases.json: the app's
# MeetingFolderPick, with the MeetingSummary model call it shares, compiled
# in and run against Apple Intelligence. Needs macOS 26 with Apple
# Intelligence on.
set -e
cd "$(dirname "$0")"
swiftc -parse-as-library -O eval.swift ../../TypeMeIt/Meetings/MeetingFolderPick.swift ../../TypeMeIt/Meetings/MeetingSummary.swift ../../TypeMeIt/Log.swift -o eval
./eval
