---
name: store-screenshots
description: Generate, edit or add the App Store screenshots in Scripts/store — framed 2560x1600 scenes of Slack, Claude and the app's own insights, history and settings tabs
---

Every screenshot is a 2560x1600 frame (`Scripts/store/frame.py`): a header
and a line of copy over a 1512x949 point window capture that runs off the
bottom, with the cloud in the scenes where the app would draw it. Two kinds
of scene:

- **painted** (`slack`, `claude`): a real capture of the other app,
  `Scripts/store/<scene>/base.png`, with its text repainted by
  `<scene>/generate.py` in that app's own font so the conversation is made up.
- **app** (`insights`, `history`, `settings`): the dev app's settings window
  over seeded history, captured by `Scripts/store/app/capture.py` into
  `Scripts/store/app/<tab>.png`.

Bases and app captures are committed; `out/` is not. Needs Google Chrome,
Pillow and numpy; the app captures also need the Debug build and `cliclick`.

## Regenerate everything

```sh
python3 Scripts/store/build.py
```

Writes `Scripts/store/out/<scene>.png`. Send those to the user.

## Change the copy

Edit `SCENES` in `Scripts/store/frame.py`: `head` and `text`, in the
listing's voice (`fastlane/metadata/en-US`: lowercase, facts, no filler). Then
`python3 Scripts/store/frame.py <scene>`.

## Change what a painted scene says

The made-up content lives at the bottom of `Scripts/store/<scene>/generate.py`
(Slack: the message list and composer; Claude: the sidebar chats and the
prompt). Edit it, then `python3 Scripts/store/<scene>/generate.py && python3
Scripts/store/frame.py <scene>`. Do not touch the pixel constants at the top
unless the base changes.

## Change what the app tabs show

The history is `Scripts/store/app/seed.py`: the last two days are written by
hand in `RECENT` (heard, typed, app), older days are random and only feed the
insights numbers. Then, with no other dev instance running
(`pgrep -fil "type me it dev.app/Contents/MacOS"`) and a fresh Debug build:

```sh
python3 Scripts/store/app/capture.py && python3 Scripts/store/frame.py insights history settings
```

`capture.py` launches the binary by path with `TYPEMEIT_SUPPORT_DIR` (never
`open`, which may start another worktree's copy), brings it to the front so
the capture has the key window's shadow and traffic lights, clicks each tab,
and for history opens the first row's "heard" panel. Pass tab names to do one.
Keep the mouse and keyboard off while it runs: a click elsewhere takes the
key window away and the capture comes out without the shadow, which the
script rejects.

## Retake a painted scene's base

The window must be exactly 1512x949 points, because `generate.py` measures
against it.

1. With the app running and the right view open, `Scripts/store/window.sh
   Slack` (or `Claude`). It prints `0, 33, 1512, 949`; anything else means the
   terminal lacks Accessibility or the app refused the size — stop and say so.
2. Ask the user to press ⌘⇧4, then space, then click the window, and wait for
   them to say it's done. macOS saves it to the Desktop with the shadow.
3. `python3 Scripts/store/capture.py <scene>` adopts the newest Desktop
   screenshot as the base (it refuses anything not 3248x2122 RGBA), then run
   the scene's `generate.py` and `frame.py`. For claude use
   `python3 Scripts/store/claude/prepare.py "<the screenshot>"` instead of
   `capture.py`: it cuts out the usage banner Claude sometimes shows above
   the composer and swaps the shortcut numbers on the first chats for
   bullets. Claude is captured in dark mode; the ink colours in its
   `generate.py` are dark-mode values.

If the layout moved, re-measure the pixel constants at the top of
`generate.py` on the new base.

## Add a scene

Painted: copy the closest `generate.py`, take a base as above, measure its
boxes, and add an entry to `SCENES` with `cloud="dark"` (or `"white"`) if the
app would show one. App tab: add the tab name to `TABS` in
`app/capture.py` and an entry to `SCENES` without `cloud`. Add the new scene
to `PAINTED` in `build.py` if it is painted.
