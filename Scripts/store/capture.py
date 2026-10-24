#!/usr/bin/env python3
"""Adopt the newest Desktop screenshot as a scene's base.png.

    python3 Scripts/store/capture.py slack

Refuses anything that is not the 3248x2122 window capture window.sh sets up,
so a mis-sized window is caught before the scene script paints over it. The
scene's own scrub() blanks what its generate.py paints over before the base
is written, so the real conversation never lands in the repo.
"""
import glob
import os
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
sys.path.insert(0, os.path.join(HERE, scene))
from generate import scrub  # noqa: E402

rgb = im.convert("RGB")
scrub(rgb)
rgb.putalpha(im.getchannel("A"))
rgb.save(base)
print(f"{newest} -> {base}")
