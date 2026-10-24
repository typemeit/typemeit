# App Store

What is in place, what is not, and what a Mac App Store build changes.
Checked against App Store Connect on 19 September 2026 with the team's API
key.

## In place

- The listing text: `fastlane/metadata`, in deliver's layout. en-US only.
- Five screenshots at 2560x1600: `python3 Scripts/store/build.py` writes
  them to `Scripts/store/out` (the `store-screenshots` skill).
- `fastlane mac listing` uploads both to the app record, in the order
  `ORDER` in the Fastfile gives. `listing metadata:false` sends the
  screenshots alone. `fastlane mac store_status` prints the record. All take
  `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_PATH`, the key `release-dmg.sh`
  notarizes with.
- The store build: the `typemeit` target in `project.yml`, the same sources
  in the App Sandbox with `network.client` for the model download, signed
  `Apple Distribution` with the `it.typeme.typemeit AppStore` profile, and no
  Sparkle (`Updates.swift` compiles to a stub without it, and the update
  rows are hidden). `MARKETING_VERSION=1.0 Scripts/release-store.sh`
  archives it, checks the entitlement set and that Sparkle is absent, and
  uploads to App Store Connect.
- The app record, since 19 September 2026: `type me it: Transcription`, SKU
  `typemeit`, Apple ID 6813950813, primary language English (U.S.), priced
  £2.99 in the UK with Apple's equivalents elsewhere, on sale in six
  storefronts only: United Kingdom, Ireland, United States, Canada,
  Australia and New Zealand. The speech model is English. The listing and
  screenshots are on it, and build 1.0 (202609201117) was uploaded on 20
  September.
- Program License Agreement accepted, membership on auto-renew, Paid Apps
  Agreement signed with a bank account submitted.

## Not in place

- Nothing on the record. Version 1.0 has the listing, screenshots, review
  contact and notes, privacy answers (nothing collected) and age rating
  (4+), and build 202609201117 is processed. It has not been submitted.

## Releasing

A `v*` tag runs `release-store` in `.github/workflows/release.yml` beside
the DMG job: it archives the `typemeit` target with the store certificates
and profile from the repo secrets (`APPLE_DISTRIBUTION_CERT_*`,
`MAC_INSTALLER_CERT_*`, `MAC_APP_STORE_PROFILE`), uploads it, renders the
screenshots with `Scripts/store/build.py`, puts the listing on the version
named by the tag with `fastlane mac listing version:X`, and submits it with
`fastlane mac submit version:X build:N`, N being the minute of the run. The
release is manual: once approved, the version is released by hand in App
Store Connect, so the store and the DMG can go out together.

The screenshots' inputs are committed (the Slack and Claude captures, the
app tab captures); only the frames are rendered on the runner. Retaking a
capture is local work (the `store-screenshots` skill).

## What the sandbox changes

The sandbox refuses the Accessibility API on other apps whatever the user
grants (probe of 15 September 2026). Posting key events, the microphone and
the clipboard still work, so dictation and the paste do. PR #127 makes a
sandboxed build detect itself and drop what it cannot do:

- the focus check before a paste;
- the read-back that learns from corrections, and its settings row;
- window titles in history, and the insights tab built on them.

Also different in a store build:

- Data lives in the app's container, not `~/Library/Application Support`,
  so history from the DMG build is not seen by the store build.
- The insights screenshot shows a tab the store build does not have; either
  the frame goes, or insights come back without the window-title
  categories.
