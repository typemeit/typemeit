#!/usr/bin/env python3
"""Capture the dev app's settings window on each tab, over seeded history.

    python3 Scripts/store/app/capture.py            # every tab
    python3 Scripts/store/app/capture.py settings   # one tab

Builds nothing: run the Debug build first (see CLAUDE.md). Launches the binary
directly with TYPEMEIT_SUPPORT_DIR pointing at the seeded store, so the real
history in ~/Library is never read, brings it to the front so the capture has
the key window's shadow and traffic lights, clicks the sidebar tab, and saves
Scripts/store/app/<tab>.png at the same 3248x2122 as the other scenes' bases.
"""
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
APP = os.path.join(ROOT, "build/dd/Build/Products/Debug/type me it dev.app/Contents/MacOS/type me it dev")
TABS = ["insights", "intelligence", "history", "settings"]  # sidebar order

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


def main(tabs):
    subprocess.run([sys.executable, os.path.join(HERE, "seed.py")], check=True)
    env = dict(os.environ, TYPEMEIT_SUPPORT_DIR=os.path.join(HERE, "store"))
    app = subprocess.Popen([APP], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        time.sleep(6)
        osascript(app.pid, 'set position of window "settings" to {0, 33}')
        osascript(app.pid, 'set size of window "settings" to {1512, 949}')
        wid = subprocess.run(["swift", "-e", WINDOW_ID, str(app.pid)], capture_output=True, text=True, check=True).stdout.split()[0]
        for tab in tabs:
            osascript(app.pid, f'click button {TABS.index(tab) + 1} of group 1 of splitter group 1 of group 1 of window "settings"')
            # Clicking through System Events can leave the app behind another
            # window; only the key window has the full shadow and coloured
            # traffic lights.
            osascript(app.pid, "set frontmost to true")
            time.sleep(1.5)
            out = os.path.join(HERE, f"{tab}.png")
            subprocess.run(["screencapture", "-l", wid, "-x", out], check=True)
            print(out)
    finally:
        app.terminate()


if __name__ == "__main__":
    main(sys.argv[1:] or TABS)
