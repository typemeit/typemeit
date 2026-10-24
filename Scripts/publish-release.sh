#!/bin/bash
# Puts a built release in the typemeit-releases R2 bucket, which typeme.it
# serves (worker.js). Run after Scripts/release-dmg.sh.
#
#   RELEASE_TAG=v1.2.0 Scripts/publish-release.sh
#
# Needs wrangler credentials: CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID in
# CI, `wrangler login` locally.
set -euo pipefail

cd "$(dirname "$0")/.."
: "${RELEASE_TAG:?set RELEASE_TAG}"

DMG="build/TypeMeIt.dmg"
APPCAST="build/updates/appcast.xml"

[ -f "$DMG" ] || { echo "$DMG is missing; run Scripts/release-dmg.sh first"; exit 1; }
[ -f "$APPCAST" ] || { echo "$APPCAST is missing; run Scripts/release-dmg.sh first"; exit 1; }
grep -q "https://typeme.it/releases/$RELEASE_TAG/TypeMeIt.dmg" "$APPCAST" \
  || { echo "$APPCAST does not point at $RELEASE_TAG"; exit 1; }

npm ci --silent --prefix Scripts/r2-put
put() { # key file content-type cache-control
  node Scripts/r2-put/put.mjs "$@"
}

# The appcast goes last: Sparkle acts on it as soon as it changes, so the DMG
# it names has to be there first.
put "releases/$RELEASE_TAG/TypeMeIt.dmg" "$DMG" application/x-apple-diskimage "public, max-age=31536000, immutable"
put "TypeMeIt.dmg" "$DMG" application/x-apple-diskimage "no-store"
put "appcast.xml" "$APPCAST" application/xml "no-cache"
