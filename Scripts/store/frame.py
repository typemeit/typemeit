#!/usr/bin/env python3
"""Lay out one App Store screenshot: a headline over an app window on flat paper.

    python3 Scripts/store/frame.py slack

Reads the scene from SCENES below, writes Scripts/store/out/<name>.png at
2560x1600. The page is rendered by headless Chrome at device scale 1, so
sizes below are final pixels. Needs Google Chrome.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out")
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
W, H = 2560, 1600

# The macOS screenshot includes a transparent margin holding the window shadow;
# this is the opaque window inside a base.png taken with window.sh, used to
# size the window rather than its shadow.
WINDOW = (112, 76, 3136, 1974)

SCENES = {
    "slack": dict(
        image="slack/out/slack.png",
        window=WINDOW,
        lead="Talk instead of typing.",
        rest="Say it, and it's typed wherever your cursor is.",
        layout="top",          # headline centred above the window
        cloud="dark",
    ),
    "claude": dict(
        image="claude/out/claude.png",
        window=WINDOW,
        lead="Speak the prompt.",
        rest="Hold a key, say it, let go. It lands in the box.",
        layout="top",
        cloud="dark",
    ),
}

CSS = """
@font-face{font-family:M;src:url(fonts/DMMono-Regular.ttf);font-weight:400}
@font-face{font-family:M;src:url(fonts/DMMono-Medium.ttf);font-weight:500}
@font-face{font-family:M;src:url(fonts/DMMono-Light.ttf);font-weight:300}
html,body{margin:0;width:%(w)dpx;height:%(h)dpx;overflow:hidden;background:#f4f4f2}
body{font-family:M,monospace;color:#0a0a0a;-webkit-font-smoothing:antialiased;position:relative}
.copy{position:absolute;left:0;right:0;top:118px;text-align:center;font-size:40px;line-height:1.3;letter-spacing:-0.01em;padding:0 240px}
.copy b{font-weight:500}
.copy span{color:#4a4a4a;font-weight:300}
.win{position:absolute;overflow:visible}
.win img{position:absolute;display:block}
.cloud{position:absolute;pointer-events:none}
"""


def render(name, s):
    os.makedirs(OUT, exist_ok=True)
    x0, y0, x1, y1 = s["window"]
    win_w, win_h = x1 - x0, y1 - y0
    # Window spans the frame width minus margins; it runs off the bottom edge
    # the way Things' screenshots do, so the headline keeps its room.
    margin = 180
    scale = (W - 2 * margin) / win_w
    img_w = round(3248 * scale)
    left = margin - round(x0 * scale)
    top = 262 - round(y0 * scale)
    cloud = ""
    if s.get("cloud"):
        # Straddles the composer, as the app draws it at the bottom of the screen.
        size = 160
        cloud = (f'<img class=cloud src="clouds/{s["cloud"]}.png" style="width:{size}px;height:{size}px;'
                 f'left:{W / 2 - size / 2}px;top:{H - size * 0.55}px">')
    html = (f'<!doctype html><meta charset=utf-8><base href="file://{HERE}/"><style>'
            f"{CSS % dict(w=W, h=H)}</style>"
            f'<div class=copy><b>{s["lead"]}</b> <span>{s["rest"]}</span></div>'
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
