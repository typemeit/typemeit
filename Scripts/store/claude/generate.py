#!/usr/bin/env python3
"""Repaint the Claude Desktop capture with our own chat list and a prompt in the composer.

    python3 Scripts/store/claude/generate.py

base.png is a 1512x949 dark-mode window capture, prepared by prepare.py (see the store-screenshots skill). Text is
set in the Anthropic Sans that ships inside Claude.app, rendered by headless
Chrome at device scale 2, which reproduces the app's rasterisation: the
sidebar rows and the composer placeholder match the capture to the pixel in
width and height. Constants are device px measured on base.png.
"""
import os
import subprocess

import numpy as np
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out")
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
DSF = 2
FONT_URL = f"file://{HERE}/fonts/sans.ttf"

# Sidebar "Chats and tasks" list: ink of the first title starts here and the
# rows repeat every 55 px; the list is clipped by the footer's rule.
LIST_X, LIST_CAP, LIST_PITCH = 190, 1003, 55
LIST_BOX = (185, 990, 683, 1885)
LIST_SIZE, LIST_COLOR = 13, "#c3c2b8"

# Composer: the placeholder's ink box, and the field's white inside.
COMPOSER_X, COMPOSER_CAP = 1307, 874
COMPOSER_BOX = (1280, 850, 2545, 940)
COMPOSER_SIZE, COMPOSER_COLOR = 16, "#e8e6e3"
CARET_H, CARET_GAP = 40, 4

# The "Active" list of scheduled runs under the composer, cleared to the
# main pane's background.
ACTIVE_BOX = (1290, 1190, 2540, 2000)


def chrome(html, out, w, h):
    path = os.path.join(OUT, "page.html")
    with open(path, "w") as f:
        f.write(html)
    subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars",
                    f"--force-device-scale-factor={DSF}", f"--window-size={w},{h}",
                    f"--screenshot={out}", f"file://{path}"], capture_output=True, check=True)
    return Image.open(out).convert("RGB")


def text(label, size, color, bg):
    """Render one line; returns the image and the ink bbox."""
    html = (f'<!doctype html><meta charset=utf-8><style>@font-face{{font-family:A;src:url({FONT_URL})}}'
            f'html,body{{margin:0;background:{bg}}}.m{{position:absolute;left:5px;top:10px;font:{size}px/1.2 A;'
            f'color:{color};-webkit-font-smoothing:antialiased;white-space:nowrap}}</style><div class=m>{label}</div>')
    im = chrome(html, os.path.join(OUT, "text.png"), 700, 60)
    lum = np.array(im.convert("L")).astype(int)
    bg_lum = int(np.array(Image.new("RGB", (1, 1), bg).convert("L"))[0, 0])
    ys, xs = np.where(np.abs(lum - bg_lum) > 60)
    return im, (xs.min(), ys.min(), xs.max() + 1, ys.max() + 1)


def paste_text(dst, label, size, color, bg, x, cap_top, clip=None):
    im, (x0, y0, x1, y1) = text(label, size, color, bg)
    piece = im.crop((x0 - 2, y0 - 3, x1 + 2, y1 + 3))
    if clip is not None:
        piece = piece.crop((0, 0, min(piece.width, clip[0] - (x - 2)), min(piece.height, clip[1] - (cap_top - 3))))
    dst.paste(piece, (x - 2, cap_top - 3))
    return x + (x1 - x0)


def hexstr(rgb):
    return "#%02x%02x%02x" % tuple(rgb[:3])


def generate(chats, prompt, out_path):
    base = Image.open(os.path.join(HERE, "base.png")).convert("RGBA")
    src = base.convert("RGB")
    draw = ImageDraw.Draw(src)

    sidebar = hexstr(src.getpixel((LIST_BOX[0], LIST_BOX[1])))
    draw.rectangle((LIST_BOX[0], LIST_BOX[1], LIST_BOX[2] - 1, LIST_BOX[3] - 1), fill=sidebar)
    for i, title in enumerate(chats):
        paste_text(src, title, LIST_SIZE, LIST_COLOR, sidebar, LIST_X, LIST_CAP + i * LIST_PITCH,
                   clip=(LIST_BOX[2], LIST_BOX[3]))

    field = hexstr(src.getpixel((COMPOSER_BOX[0], COMPOSER_BOX[1])))
    draw.rectangle((COMPOSER_BOX[0], COMPOSER_BOX[1], COMPOSER_BOX[2] - 1, COMPOSER_BOX[3] - 1), fill=field)
    end = paste_text(src, prompt, COMPOSER_SIZE, COMPOSER_COLOR, field, COMPOSER_X, COMPOSER_CAP)
    top = COMPOSER_CAP - (CARET_H - 31) // 2
    draw.rectangle((end + CARET_GAP, top, end + CARET_GAP + 1, top + CARET_H), fill=COMPOSER_COLOR)

    draw.rectangle((ACTIVE_BOX[0], ACTIVE_BOX[1], ACTIVE_BOX[2] - 1, ACTIVE_BOX[3] - 1),
                   fill=hexstr(src.getpixel((ACTIVE_BOX[0], ACTIVE_BOX[1]))))

    src.putalpha(base.getchannel("A"))
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    src.save(out_path)
    return out_path


if __name__ == "__main__":
    chats = [
        "Reply to Sam about pricing",
        "Trip to Lisbon in October",
        "Board call notes",
        "Book a table for six on Friday",
        "Sourdough starter timing",
        "Explain the tax letter",
        "Birthday ideas for Anna",
        "Offsite agenda draft",
        "Fix the squeaky door",
        "Lemon cake recipe",
        "Compare running shoes",
        "Summarise the lease",
        "Kitchen repaint plan",
        "Packing list for Scotland",
        "Thank-you note to the team",
        "Where to stay in Porto",
        "Weekend plan with the kids",
    ]
    print(generate(chats, "Build me a minimal transcription app for the Mac, and make no mistakes",
                   os.path.join(OUT, "claude.png")))
