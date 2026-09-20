#!/bin/bash
# The Mac App Store channel: the sandboxed `typemeit` target, archived, signed
# for the store and uploaded to App Store Connect, where it shows up under the
# app's builds a few minutes later for the version to pick.
#
#   MARKETING_VERSION=1.0 Scripts/release-store.sh
#
# Requires DEVELOPMENT_TEAM, and ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH for
# the upload. The listing (text and screenshots) goes up separately with
# `fastlane mac listing`. The direct-download DMG is release-dmg.sh.
set -euo pipefail

cd "$(dirname "$0")/.."
: "${DEVELOPMENT_TEAM:?set DEVELOPMENT_TEAM}"
: "${ASC_KEY_ID:?set ASC_KEY_ID}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
: "${ASC_KEY_PATH:?set ASC_KEY_PATH}"
: "${MARKETING_VERSION:?set MARKETING_VERSION to the store version, e.g. 1.0}"

BUILD="$PWD/build/store"
ARCHIVE="$BUILD/typemeit.xcarchive"
APP="$ARCHIVE/Products/Applications/type me it.app"

# Always moves forward, so it outranks every earlier build with no shared-state
# lookup. A commit count does not survive re-running the same commit.
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"

rm -rf "$ARCHIVE" "$BUILD/export"
mkdir -p "$BUILD"
xcodegen generate

xcodebuild archive \
  -project TypeMeIt.xcodeproj \
  -scheme typemeit \
  -configuration Release \
  -archivePath "$ARCHIVE" \
  -derivedDataPath "$BUILD/DerivedData" \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  MARKETING_VERSION="$MARKETING_VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER"

# The store build is sandboxed and nothing else: a set that has grown, or lost
# the sandbox, fails here rather than in review.
EXPECTED_ENTITLEMENTS="com.apple.application-identifier
com.apple.developer.team-identifier
com.apple.security.app-sandbox
com.apple.security.device.audio-input
com.apple.security.network.client"
entitlements="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -convert xml1 -o - - 2>/dev/null | sed -n 's|.*<key>\(.*\)</key>.*|\1|p' | sort || true)"
if [ "$entitlements" != "$EXPECTED_ENTITLEMENTS" ]; then
  echo "the store build's entitlements are not the expected set"
  echo "expected: $(tr '\n' ' ' <<<"$EXPECTED_ENTITLEMENTS")"
  echo "found:    $(tr '\n' ' ' <<<"${entitlements:-(none)}")"
  exit 1
fi
if [ -d "$APP/Contents/Frameworks/Sparkle.framework" ]; then
  echo "the store build carries Sparkle; the store rejects a self-updating app"
  exit 1
fi

cat > "$BUILD/ExportOptions-app-store.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>$DEVELOPMENT_TEAM</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Apple Distribution</string>
  <key>installerSigningCertificate</key><string>3rd Party Mac Developer Installer</string>
  <key>provisioningProfiles</key>
  <dict><key>it.typeme.typemeit</key><string>it.typeme.typemeit AppStore</string></dict>
  <key>uploadSymbols</key><true/>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$BUILD/ExportOptions-app-store.plist" \
  -exportPath "$BUILD/export" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"

echo "uploaded type me it $MARKETING_VERSION ($BUILD_NUMBER) to App Store Connect"
