---
name: store-capture
description: Retake the base window capture for an App Store screenshot scene (slack, claude, notes) and regenerate the framed scene
---

Each scene in `Scripts/store/<scene>/` is painted over a real window capture, and
its `generate.py` measures everything against a 1512x949 point window, so the
capture must be taken at exactly that size. Scenes and the app they capture:
slack → Slack, claude → Claude, notes → Notes.

1. Size the window (the app must be running with the right view open):

   ```sh
   Scripts/store/window.sh Slack
   ```

   It prints `0, 33, 1512, 949`. Anything else means Accessibility is missing for
   the terminal, or the app refused the size — stop and say so.

2. Ask the user to take the screenshot themselves: press ⌘⇧4, then space, then
   click the window. macOS saves it to the Desktop with the shadow, which the
   scripts expect. Wait for them to say it's done.

3. Adopt it and rebuild:

   ```sh
   python3 Scripts/store/capture.py slack && python3 Scripts/store/slack/generate.py && python3 Scripts/store/frame.py slack
   ```

   `capture.py` refuses a capture that is not 3248x2122 RGBA. Send the user
   `Scripts/store/out/<scene>.png`.

If the window geometry changes on purpose, re-measure the constants at the top of
the scene's `generate.py` and its window box in `frame.py`.

## insights

The insights scene is the app's own settings window over made-up history, so
there is nothing to repaint and no need for the user to screenshot. Build the
dev app, then:

```sh
python3 Scripts/store/insights/seed.py
TYPEMEIT_SUPPORT_DIR="$PWD/Scripts/store/insights/store" "build/dd/Build/Products/Debug/type me it dev.app/Contents/MacOS/type me it dev" &
```

Wait for the settings window, find its window number with
`CGWindowListCopyWindowInfo` filtered to that pid and the name `settings`, then
`screencapture -l <number> -x Scripts/store/insights/base.png` and
`python3 Scripts/store/frame.py insights`. Quit the app afterwards. Launch the
binary directly, not with `open`: the env var has to reach the process, and
`open` may start another worktree's copy.
