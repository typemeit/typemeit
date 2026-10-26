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
- The dictation key is a system hotkey (Carbon `RegisterEventHotKey`), ⌥
  space by default and changeable in settings. ⌥ plays Fn: the recording
  lasts while it is held, space with it pins, a quick tap cancels, Esc
  cancels. Fn alone needs a CGEvent tap, which App Review refused. The
  🌐 key onboarding step is not shown, and the private call behind it is
  compiled out (`APP_STORE`).
- Accessibility is asked for only to post ⌘V, as clipboard managers on the
  store do. Without it the app offers to copy the transcript instead.
- Onboarding asks for each permission from its continue button and moves
  on after a refusal; the DMG build keeps its grant buttons.
- Open at login starts off.
- Settings › about links the privacy policy.
- `-previewStore 1` makes a Debug build look like the store build; the app
  screenshots are captured that way.

## App Review

Build 1.0.0 (202609231830) was rejected on 27 September 2026 under:

- 5.1.1(iv): the screen before the microphone prompt had a "grant" button.
  The press that brings up a permission prompt must read "continue" or
  "next", and a refusal must let the user move on.
- 2.4.5: Accessibility used for a keyboard event tap, "a non-accessibility
  purpose".

Before each submission, check the store build against these, and against
the rest of the audit made that day:

- Every permission prompt is reached through a "continue" button, and the
  app moves on when the user refuses it. The Info.plist purpose string
  names what the permission is for in the store build.
- No event tap, no Input Monitoring, no `AXIsProcessTrusted` read of other
  apps. Accessibility is asked for only for posting ⌘V.
- No private symbols: `strings` on the store binary shows no
  `TISUpdateFnUsageType`.
- Nothing is registered to open at login until the user turns it on.
- The listing and every screenshot show only what the store build has: no
  Fn, no insights tab.
- The privacy policy is linked inside the app (settings › about), and it
  and the terms (web/privacy.html, web/terms.html) describe the store
  version: its hotkey, what it does not read, no Sparkle, the price and
  Apple's licence agreement.
- Apple's marks are written as Apple writes them in the listing and the
  screenshot captions: Apple Intelligence, Mac. The in-app copy stays
  lowercase.
- The listing says the app needs Apple Intelligence turned on, since it
  will not run without it.
- The support URL is typeme.it, which shows the contact address.
- App Review notes in App Store Connect say how to try it: Apple
  Intelligence on, the model download, ⌥ space, and what Accessibility is
  for.
- Screen Recording rows are off by default and say what is read.
