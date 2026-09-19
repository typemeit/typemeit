# App Store

What is in place, what is not, and what a Mac App Store build changes.
Checked against App Store Connect on 19 September 2026 with the team's API
key.

## In place

- The listing text: `fastlane/metadata`, in deliver's layout. en-US only.
- Five screenshots at 2560x1600: `python3 Scripts/store/build.py` writes
  them to `Scripts/store/out` (the `store-screenshots` skill).
- `fastlane mac listing` uploads both to the app record. It uploads no
  build and submits nothing. `fastlane mac store_status` prints the record.
  Both take `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_PATH`, the key
  `release-dmg.sh` notarizes with; it has App Store Connect access.

## Not in place

- The app record exists since 19 September 2026: `type me it:
  Transcription`, SKU `typemeit`, Apple ID 6813950813, primary language
  English (U.S.), priced £2.99 in the UK with Apple's equivalents elsewhere.
  Pricing takes effect only once the Paid Apps agreement is signed, and the
  updated Developer Program License Agreement has to be accepted by the
  Account Holder before a new app can be submitted.
- No build the store accepts. The app ships as a Developer ID DMG with
  Sparkle updates, which the store rejects: a store build needs the App
  Sandbox, `Apple Distribution` signing with a Mac App Store provisioning
  profile, and no Sparkle.

## What the sandbox changes

The sandbox refuses the Accessibility API on other apps whatever the user
grants (probe of 15 September 2026). Posting key events, the microphone and
the clipboard still work, so dictation and the paste do. PR #127 makes a
sandboxed build detect itself and drop what it cannot do:

- the focus check before a paste;
- the read-back that learns from corrections, and its settings row;
- window titles in history, and the insights tab built on them.

It is not merged. The store build depends on it.

Also different in a store build:

- Entitlements: `app-sandbox`, `device.audio-input`, `network.client` (the
  speech model is downloaded from a GitHub release on first run, 600 MB).
  PR #126's entitlement guard is for the DMG build only and would need to
  allow the store set.
- No Sparkle: `Updates.swift`, the version row's update actions, the
  `SUFeedURL` keys and the package dependency come out of the store target.
- Data lives in the app's container, not `~/Library/Application Support`,
  so history from the DMG build is not seen by the store build.

## Order of work

1. Merge PR #127 (and #126 with the store set allowed).
2. Add a `typemeit` target in `project.yml`: same sources, sandbox
   entitlements, Apple Distribution signing, Sparkle excluded behind a
   build flag.
3. Sign the Paid Apps agreement and accept the updated license agreement
   in App Store Connect.
4. `fastlane mac listing` for the text and screenshots.
5. Archive the store target, upload with `deliver` or Transporter, and
   submit for review with notes on the Input Monitoring and Microphone
   prompts.
