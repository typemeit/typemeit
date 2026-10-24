#!/bin/sh
# Sizes an app's front window so a window screenshot (⌘⇧4, space, click) has
# the geometry the scene scripts were measured against: 1512x949 points at the
# top left of the display, which on a 2x screen with the shadow margin comes
# out at 3248x2122 device px. Needs Accessibility for the terminal running it.
#
#     Scripts/store/window.sh Slack
#     Scripts/store/window.sh Notes
set -e
app=${1:?app name}
osascript - "$app" <<'AS'
on run argv
    set app_name to item 1 of argv
    tell application app_name to activate
    tell application "System Events" to tell process app_name
        set position of window 1 to {0, 33}
        set size of window 1 to {1512, 949}
        get {position, size} of window 1
    end tell
end run
AS
