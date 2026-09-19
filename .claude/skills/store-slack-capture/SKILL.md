---
name: store-slack-capture
description: Retake the Slack base capture for the App Store screenshot and regenerate the framed scene
---

The Slack scene in `Scripts/store` is painted over a real Slack window capture.
`generate.py` measures everything against a 1512x949 point window, so the capture
must be taken at exactly that size.

1. Size the window (Slack must be running; the DM to overlay should be open):

   ```sh
   Scripts/store/slack/window.sh
   ```

   It prints `0, 33, 1512, 949`. Anything else means Accessibility is missing for
   the terminal, or Slack refused the size — stop and say so.

2. Ask the user to take the screenshot themselves: press ⌘⇧4, then space, then
   click the Slack window. macOS saves it to the Desktop with the shadow, which
   the scripts expect. Wait for them to say it's done.

3. Adopt it and rebuild:

   ```sh
   python3 Scripts/store/slack/capture.py && python3 Scripts/store/slack/generate.py && python3 Scripts/store/frame.py slack
   ```

   `capture.py` refuses a capture that is not 3248x2122 RGBA. Send the user
   `Scripts/store/out/slack.png`.

If the window geometry changes on purpose, re-measure the constants at the top of
`generate.py` and `SLACK_WINDOW` in `frame.py`.
