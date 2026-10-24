#!/bin/bash
# Builds the type me it camera's installer, puts it in /Applications (macOS
# installs a system extension only from there) and opens it. The first time,
# macOS asks for the camera to be allowed in System Settings. type me it then
# shows the real camera through it while a meeting app shows it.
#
#   Scripts/install-camera.sh            install, or replace with this build
#   Scripts/install-camera.sh -remove    uninstall
#
# Requires the profile Scripts/signing-profiles.swift makes. With ASC_KEY_ID,
# ASC_ISSUER_ID and ASC_KEY_PATH set, the installer is notarized first.
set -euo pipefail

cd "$(dirname "$0")/.."
TEAM="${DEVELOPMENT_TEAM:-Z28DW76Y3W}"
DERIVED="${DERIVED_DATA:-/tmp/typemeit-dd}"
BUILT="$DERIVED/Build/Products/Release/type me it camera.app"
INSTALLED="/Applications/type me it camera.app"

if [ "${1:-}" = "-remove" ]; then
  open -W -n "$INSTALLED" --args -remove
  rm -rf "$INSTALLED"
  exit 0
fi

DEVELOPMENT_TEAM="$TEAM" xcodegen generate
# Notarization refuses debug dylibs, the get-task-allow entitlement (which
# `xcodebuild build` adds even in Release) and untimestamped signatures. A new
# build number each time, or macOS keeps the extension it already runs.
xcodebuild -project TypeMeIt.xcodeproj -scheme Camera -configuration Release -derivedDataPath "$DERIVED" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO OTHER_CODE_SIGN_FLAGS=--timestamp CURRENT_PROJECT_VERSION="$(date +%s)" build -quiet

if [ -n "${ASC_KEY_ID:-}" ]; then
  ZIP="$DERIVED/type-me-it-camera.zip"
  ditto -c -k --keepParent "$BUILT" "$ZIP"
  xcrun notarytool submit "$ZIP" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait
  xcrun stapler staple "$BUILT"
fi

rm -rf "$INSTALLED"
ditto "$BUILT" "$INSTALLED"
open "$INSTALLED"
