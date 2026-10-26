#!/usr/bin/env python3
"""Capture the dev app's settings window on each tab, over seeded history.

    python3 Scripts/store/app/capture.py            # every tab
    python3 Scripts/store/app/capture.py settings   # one tab

Builds nothing: run the Debug build first (see CLAUDE.md). Needs cliclick (brew). Launches the binary
directly with TYPEMEIT_SUPPORT_DIR pointing at the seeded store, so the real
history in ~/Library is never read, brings it to the front so the capture has
the key window's shadow and traffic lights, clicks the sidebar tab, and saves
Scripts/store/app/<tab>.png at the same 3248x2122 as the other scenes' bases.
"""
import os
import subprocess
import sys
import time

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
APP = os.path.join(ROOT, "build/dd/Build/Products/Debug/type me it dev.app/Contents/MacOS/type me it dev")
TABS = ["history", "dictionary", "settings"]  # sidebar order in the store build
# The settings groups opened for the capture, by position in the page
# (dictation, clean-up, ...), bottom one first so the positions above it
# hold. Dictation holds the store build's hotkey.
OPEN_GROUPS = [1]
# By path: the dev app is not sandboxed, but a container for its bundle id
# exists, and `defaults` would otherwise write to the plist in there instead.
DEFAULTS = os.path.expanduser("~/Library/Preferences/it.typeme.typemeit.dev.plist")
KEEP = "100"  # the smallest "keep" choice, shown in the history capture's picker


def default(key):
    r = subprocess.run(["defaults", "read", DEFAULTS, key], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else None


def set_default(key, value):
    if value is None:
        subprocess.run(["defaults", "delete", DEFAULTS, key], check=True, capture_output=True)
    else:
        subprocess.run(["defaults", "write", DEFAULTS, key, "-int", value], check=True)

WINDOW_ID = '''
import AppKit
let pid = Int32(CommandLine.arguments[1])!
NSRunningApplication(processIdentifier: pid)!.activate(options: [.activateAllWindows])
Thread.sleep(forTimeInterval: 1)
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in list where (w["kCGWindowOwnerPID"] as? Int32) == pid && (w["kCGWindowName"] as? String) == "settings" {
    print(w["kCGWindowNumber"]!)
}
'''


def osascript(pid, script):
    subprocess.run(["osascript", "-e", f'tell application "System Events" to tell (first process whose unix id is {pid}) to {script}'],
                   check=True, capture_output=True)


def sidebar_buttons(pid):
    """The sidebar's page buttons, top to bottom: the window's buttons that
    sit at its left edge (the window is placed at x = 0)."""
    out = subprocess.run(["osascript", "-e", f'tell application "System Events" to tell (first process whose unix id is {pid}) to get position of every button of group 1 of window "settings"'],
                         check=True, capture_output=True, text=True).stdout
    numbers = [int(n) for n in out.replace(",", " ").split()]
    positions = list(zip(numbers[0::2], numbers[1::2]))
    return [i + 1 for i, (x, y) in sorted(enumerate(positions), key=lambda p: p[1][1]) if x == 0]


def clone_model():
    """Without the speech model the app opens on onboarding, not settings.
    An APFS clone of the installed one costs no download and no disk."""
    asr = os.path.join(HERE, "store", "models", "asr")
    if not os.path.isdir(asr) or not os.listdir(asr):
        installed = os.path.expanduser("~/Library/Application Support/TypeMeIt/models/asr")
        os.makedirs(asr, exist_ok=True)
        for version in os.listdir(installed):
            subprocess.run(["cp", "-c", "-R", os.path.join(installed, version), asr], check=True)


def main(tabs):
    subprocess.run([sys.executable, os.path.join(HERE, "seed.py")], check=True)
    clone_model()
    env = dict(os.environ, TYPEMEIT_SUPPORT_DIR=os.path.join(HERE, "store"))
    # The dev app's own preferences are read as it launches; the keep limit
    # only prunes on the next dictation, so the seeded count stands.
    keep_before = default("historyLimit")
    set_default("historyLimit", KEEP)
    # Looks like the store build: its hotkey in place of Fn, no insights tab.
    app = subprocess.Popen([APP, "-previewStore", "1"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        time.sleep(6)
        # A launch restores the windows open at the last quit, which may be
        # none; opening the running bundle again brings settings up.
        subprocess.run(["open", APP.split("/Contents/MacOS/")[0]], check=True)
        time.sleep(2)
        osascript(app.pid, 'set position of window "settings" to {0, 33}')
        osascript(app.pid, 'set size of window "settings" to {1512, 949}')
        wid = subprocess.run(["swift", "-e", WINDOW_ID, str(app.pid)], capture_output=True, text=True, check=True).stdout.split()[0]
        pages = sidebar_buttons(app.pid)
        for tab in tabs:
            osascript(app.pid, f'click button {pages[TABS.index(tab)]} of group 1 of window "settings"')
            # Clicking through System Events can leave the app behind another
            # window; only the key window has the full shadow and coloured
            # traffic lights.
            osascript(app.pid, "set frontmost to true")
            time.sleep(1.5)
            osascript(app.pid, "set frontmost to true")  # again, in case a click elsewhere took it back
            time.sleep(0.3)
            if tab == "settings":
                for group in OPEN_GROUPS:
                    osascript(app.pid, f'click button {group} of scroll area 1 of group 1 of window "settings"')
                    time.sleep(0.5)
                osascript(app.pid, "set frontmost to true")
                time.sleep(0.5)
            out = os.path.join(HERE, f"{tab}.png")
            subprocess.run(["screencapture", "-l", wid, "-x", out], check=True)
            if Image.open(out).size != (3248, 2122):
                sys.exit(f"{out} is not the key window's capture; keep the mouse and keyboard off while this runs and retry")
            print(out)
    finally:
        app.terminate()
        app.wait()
        set_default("historyLimit", keep_before)


if __name__ == "__main__":
    main(sys.argv[1:] or TABS)
