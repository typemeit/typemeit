#!/bin/sh
# Sizes the Slack window so a window screenshot (⌘⇧4, space, click) matches
# the geometry generate.py was measured against: 1512x949 points at the top
# left of the display, which on a 2x screen with the shadow margin comes out
# at 3248x2122 device px. Needs Accessibility for the terminal running it.
set -e
osascript <<'AS'
tell application "Slack" to activate
tell application "System Events" to tell process "Slack"
    set position of window 1 to {0, 33}
    set size of window 1 to {1512, 949}
    get {position, size} of window 1
end tell
AS
