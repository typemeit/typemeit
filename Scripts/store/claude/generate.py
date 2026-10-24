#!/usr/bin/env python3
"""Repaint the Claude Desktop capture with our own chat list and a prompt in the composer.

    python3 Scripts/store/claude/generate.py

base.png is a 1512x949 dark-mode window capture, prepared by prepare.py (see the store-screenshots skill),
which runs scrub() so the captured chat titles and runs never reach git. Text is
set in the Anthropic Sans that ships inside Claude.app, rendered by headless
Chrome at device scale 2, which reproduces the app's rasterisation: the
sidebar rows and the composer placeholder match the capture to the pixel in
width and height. Constants are device px measured on base.png.
"""
import os
import sys

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
from paint import Painter

OUT = os.path.join(HERE, "out")
FONT_URL = f"file://{HERE}/fonts/sans.ttf"
PAINT = Painter(OUT, dsf=2, text_width=700)

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


def hexstr(rgb):
    return "#%02x%02x%02x" % tuple(rgb[:3])


def scrub(im):
    """Clear, in place, the chat list, the composer and the Active runs, each to the colour at its top-left corner."""
    draw = ImageDraw.Draw(im)
    for box in (LIST_BOX, COMPOSER_BOX, ACTIVE_BOX):
        draw.rectangle((box[0], box[1], box[2] - 1, box[3] - 1), fill=im.getpixel(box[:2]))
    # The footer's rule, the row under the list, carries the tops of the next title's letters.
    rule = (LIST_BOX[0], LIST_BOX[3], LIST_BOX[2] - 1, LIST_BOX[3])
    draw.line(rule, fill=im.getpixel(rule[:2]))


def generate(chats, prompt, out_path):
    base = Image.open(os.path.join(HERE, "base.png")).convert("RGBA")
    src = base.convert("RGB")
    scrub(src)
    draw = ImageDraw.Draw(src)

    sidebar = hexstr(src.getpixel(LIST_BOX[:2]))
    for i, title in enumerate(chats):
        PAINT.paste_text(src, title, FONT_URL, LIST_SIZE, LIST_COLOR, sidebar, LIST_X, LIST_CAP + i * LIST_PITCH,
                   clip=(LIST_BOX[2], LIST_BOX[3]))

    field = hexstr(src.getpixel(COMPOSER_BOX[:2]))
    end = PAINT.paste_text(src, prompt, FONT_URL, COMPOSER_SIZE, COMPOSER_COLOR, field, COMPOSER_X, COMPOSER_CAP)
    top = COMPOSER_CAP - (CARET_H - 31) // 2
    draw.rectangle((end + CARET_GAP, top, end + CARET_GAP + 1, top + CARET_H), fill=COMPOSER_COLOR)

    src.putalpha(base.getchannel("A"))
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    src.save(out_path)
    return out_path


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
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
    print(generate(chats, "Build me a minimal transcription app for the Mac, make no mistakes",
                   os.path.join(OUT, "claude.png")))
