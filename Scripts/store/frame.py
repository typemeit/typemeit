#!/usr/bin/env python3
"""Lay out one App Store screenshot: one line of copy over an app window on flat paper.

    python3 Scripts/store/frame.py slack

Reads the scene from SCENES below, writes Scripts/store/out/<name>.png at
2560x1600. The page is rendered by headless Chrome at device scale 1, so
sizes below are final pixels. Needs Google Chrome.
"""
import os
import subprocess
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out")
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
W, H = 2560, 1600

# A header and a line under it, in the listing's voice (fastlane/metadata):
# lowercase, facts. The listing name already says "Transcription App", so
# the frames say what is different, not what it is.
SCENES = {
    "slack": dict(
        image="slack/out/slack.png", cloud="dark",
        head="hold fn, speak, let go.",
        text="typed wherever the cursor is - be it slack, claude, anything with a text box.",
    ),
    "claude": dict(
        image="claude/out/claude.png", cloud="white",
        head="tidied by apple intelligence.",
        text="fillers dropped, punctuation put in, on this mac. nothing leaves the computer.",
    ),
    "insights": dict(
        image="app/insights.png",
        head="three times faster than typing.",
        text="every dictation counted: words, speed, streaks, and the apps you spoke into.",
    ),
    "history": dict(
        image="app/history.png",
        head="everything on your mac.",
        text="transcribed, formatted and tidied on device, and kept here with what was heard. nothing is sent anywhere.",
    ),
    "settings": dict(
        image="app/settings.png",
        head="customise your cloud and config.",
        text="custom colour and position.",
    ),
}

CSS = """
@font-face{font-family:M;src:url(fonts/DMMono-Regular.ttf);font-weight:400}
@font-face{font-family:M;src:url(fonts/DMMono-Medium.ttf);font-weight:500}
@font-face{font-family:M;src:url(fonts/DMMono-Light.ttf);font-weight:300}
html,body{margin:0;width:%(w)dpx;height:%(h)dpx;overflow:hidden;background:#f4f4f2}
body{font-family:M,monospace;color:#0a0a0a;-webkit-font-smoothing:antialiased;position:relative}
.copy{position:absolute;left:0;right:0;top:96px;text-align:center;padding:0 200px;letter-spacing:-0.01em}
.copy h1{margin:0;font-size:44px;font-weight:500;line-height:1.2}
.copy p{margin:14px 0 0;font-size:26px;font-weight:300;line-height:1.4;color:#4a4a4a}
.win{position:absolute;overflow:visible}
.win img{position:absolute;display:block}
.cloud{position:absolute;pointer-events:none}
"""


def window_box(path):
    """The opaque window inside a capture, ignoring the transparent margin
    that holds its shadow."""
    alpha = np.array(Image.open(path).getchannel("A"))
    ys, xs = np.where(alpha == 255)
    return xs.min(), ys.min(), xs.max() + 1, ys.max() + 1


def render(name, s):
    os.makedirs(OUT, exist_ok=True)
    image = os.path.join(HERE, s["image"])
    x0, y0, x1, y1 = window_box(image)
    win_w = x1 - x0
    # Window spans the frame width minus margins; it runs off the bottom edge
    # the way Things' screenshots do, so the headline keeps its room.
    margin = 180
    scale = (W - 2 * margin) / win_w
    img_w = round(Image.open(image).width * scale)
    left = margin - round(x0 * scale)
    top = 300 - round(y0 * scale)
    cloud = ""
    if s.get("cloud"):
        # Sits fully inside the frame just above the bottom edge, where the app
        # draws it on screen.
        size = 160
        cloud = (f'<img class=cloud src="clouds/{s["cloud"]}.png" style="width:{size}px;height:{size}px;'
                 f'left:{W / 2 - size / 2}px;top:{H - size - 40}px">')
    html = (f'<!doctype html><meta charset=utf-8><base href="file://{HERE}/"><style>'
            f"{CSS % dict(w=W, h=H)}</style>"
            f'<div class=copy><h1>{s["head"]}</h1><p>{s["text"]}</p></div>'
            f'<div class=win style="left:{left}px;top:{top}px"><img src="{s["image"]}" style="width:{img_w}px"></div>'
            f"{cloud}")
    page = os.path.join(OUT, f"{name}.html")
    with open(page, "w") as f:
        f.write(html)
    out = os.path.join(OUT, f"{name}.png")
    subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars",
                    "--force-device-scale-factor=1", f"--window-size={W},{H}",
                    f"--screenshot={out}", f"file://{page}"], capture_output=True, check=True, cwd=HERE)
    return out


if __name__ == "__main__":
    for name in sys.argv[1:] or SCENES:
        print(render(name, SCENES[name]))
