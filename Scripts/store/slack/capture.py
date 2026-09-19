#!/usr/bin/env python3
"""Adopt the newest Desktop screenshot as slack/base.png.

    python3 Scripts/store/slack/capture.py

Refuses anything that is not the 3248x2122 window capture window.sh sets up,
so a mis-sized window is caught before generate.py paints over it.
"""
import glob
import os
import shutil
import sys

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
BASE = os.path.join(HERE, "base.png")
EXPECTED = (3248, 2122)

shots = sorted(glob.glob(os.path.expanduser("~/Desktop/Screenshot *.png")), key=os.path.getmtime)
if not shots:
    sys.exit("no Screenshot *.png on the Desktop")
newest = shots[-1]
im = Image.open(newest)
if im.size != EXPECTED or im.mode != "RGBA":
    sys.exit(f"{newest} is {im.size} {im.mode}, expected {EXPECTED} RGBA: run window.sh and capture the window again")
shutil.copy(newest, BASE)
print(f"{newest} -> {BASE}")
