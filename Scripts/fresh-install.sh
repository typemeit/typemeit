#!/bin/zsh
# Runs the dev app as a fresh install, to test onboarding: an empty data dir
# (so the speech model downloads again) and empty dev preferences. The release
# app's data and the real dev preferences are left alone; `restore` puts the
# dev preferences back.
#
#   Scripts/fresh-install.sh            build, then launch fresh
#   Scripts/fresh-install.sh restore    quit dev, put the dev preferences back
#
#   SKIP_BUILD=1          launch the last build
#   STEP=globeKey         open onboarding on that step (OnboardingView.Step)
#   PERMISSIONS=reset     also revoke the dev app's microphone, accessibility
#                         and screen recording grants
set -euo pipefail
cd "${0:A:h}/.."

BUNDLE_ID=it.typeme.typemeit.dev
APP="/tmp/typemeit-dd/Build/Products/Debug/type me it dev.app"
PROCESS="type me it dev.app/Contents/MacOS"
# The plist by path: `defaults` on the bare bundle id reads the old sandbox container.
PREFS="$HOME/Library/Preferences/$BUNDLE_ID.plist"
FRESH_DIR=/tmp/typemeit-fresh
DATA_DIR="$FRESH_DIR/data"
PREFS_BACKUP="$FRESH_DIR/dev-prefs-backup.plist"
LOG="$HOME/Library/Logs/TypeMeIt/debug.log"

stop_dev() {
    pgrep -fq "$PROCESS" || return 0
    # Quitting mid-recording cuts the meeting; the release app logs here too.
    if [[ -f $LOG ]] && grep -E "Meeting recording (started|stopped)" "$LOG" | tail -1 | grep -q started; then
        echo "a meeting is recording (last line in $LOG); stop it first" >&2
        exit 1
    fi
    pkill -f "$PROCESS"
    while pgrep -fq "$PROCESS"; do sleep 0.2; done
}

if [[ ${1:-} == restore ]]; then
    stop_dev
    [[ -f $PREFS_BACKUP ]] || { echo "no backup at $PREFS_BACKUP" >&2; exit 1; }
    defaults import "$PREFS" "$PREFS_BACKUP"
    rm "$PREFS_BACKUP"
    echo "dev preferences restored"
    exit 0
fi

if [[ -z ${SKIP_BUILD:-} ]]; then
    DEVELOPMENT_TEAM=Z28DW76Y3W xcodegen generate >/dev/null
    xcodebuild -project TypeMeIt.xcodeproj -scheme TypeMeIt -configuration Debug -derivedDataPath /tmp/typemeit-dd build \
        'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) Diarizer' -quiet
fi

stop_dev

mkdir -p "$FRESH_DIR"
# Keep the first backup across repeated fresh runs: later runs would back up
# the fresh-install preferences over the real ones.
if [[ -f $PREFS && ! -f $PREFS_BACKUP ]]; then
    defaults export "$PREFS" "$PREFS_BACKUP"
    echo "dev preferences backed up; Scripts/fresh-install.sh restore puts them back"
fi
defaults delete "$PREFS" 2>/dev/null || true

rm -rf "$DATA_DIR"
mkdir -p "$DATA_DIR"

if [[ ${PERMISSIONS:-} == reset ]]; then
    for service in Microphone Accessibility ScreenCapture; do
        tccutil reset "$service" "$BUNDLE_ID" >/dev/null
    done
    echo "dev app permissions revoked"
fi

app_args=()
[[ -n ${STEP:-} ]] && app_args=(--args -onboardingStep "$STEP")
open --env "TYPEMEIT_SUPPORT_DIR=$DATA_DIR" "$APP" "${app_args[@]}"
echo "launched fresh on $DATA_DIR"
