#!/usr/bin/env python3
"""Regenerate every App Store screenshot from what is committed.

    python3 Scripts/store/build.py

Paints the slack and claude scenes over their base captures, then frames all
of them, the app captures included, into Scripts/store/out/<scene>.png at
2560x1600. Nothing here needs the dev app or the user: the app tabs are
recaptured separately with Scripts/store/app/capture.py.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PAINTED = ["slack", "claude"]

for scene in PAINTED:
    subprocess.run([sys.executable, os.path.join(HERE, scene, "generate.py")], check=True)
subprocess.run([sys.executable, os.path.join(HERE, "frame.py")], check=True)
