#!/usr/bin/env python3
"""Adopt the newest Desktop screenshot as a scene's base.png.

    python3 Scripts/store/capture.py slack
    python3 Scripts/store/capture.py notes

Refuses anything that is not the 3248x2122 window capture window.sh sets up,
so a mis-sized window is caught before the scene script paints over it.
"""
import glob
import os
import shutil
import sys

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
EXPECTED = (3248, 2122)

scene = sys.argv[1]
base = os.path.join(HERE, scene, "base.png")
shots = sorted(glob.glob(os.path.expanduser("~/Desktop/Screenshot *.png")), key=os.path.getmtime)
if not shots:
    sys.exit("no Screenshot *.png on the Desktop")
newest = shots[-1]
im = Image.open(newest)
if im.size != EXPECTED or im.mode != "RGBA":
    sys.exit(f"{newest} is {im.size} {im.mode}, expected {EXPECTED} RGBA: run window.sh and capture the window again")
os.makedirs(os.path.dirname(base), exist_ok=True)
shutil.copy(newest, base)
print(f"{newest} -> {base}")
