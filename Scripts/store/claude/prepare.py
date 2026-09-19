#!/usr/bin/env python3
"""Turn a raw Claude capture into base.png for generate.py.

    python3 Scripts/store/claude/prepare.py "~/Desktop/Screenshot ....png"

Claude shows a usage banner above the composer some days; it is cut out and
the composer moved up into its place, so the pixel constants in generate.py
hold either way. The first nine chats carry shortcut numbers instead of
bullets while the composer is focused; each is swapped for the bullet of
the tenth row.
"""
import os
import sys

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
BG = (21, 21, 21)
FIELD = (32, 32, 31)      # the composer's fill
SIDEBAR = (17, 17, 17)
MAIN_X = (1250, 2600)
COMPOSER_TOP = 836        # where generate.py expects the composer's top border
BANNER_TOP = 836          # where a banner's top border would be
LIST_PITCH, ROWS = 55, 9  # numbered rows
BULLET = (136, 1489, 176, 1525)   # the tenth row's bullet, sidebar included
BULLET_PITCH_FROM = 9             # rows above it that get a copy


def composer_top(im):
    """The composer's top border: two rows above its first row of fill."""
    for y in range(BANNER_TOP, 1300):
        if im.getpixel((1400, y)) == FIELD:
            return y - 2
    raise SystemExit("no composer found")


def main(raw):
    im = Image.open(os.path.expanduser(raw)).convert("RGBA")
    if im.size != (3248, 2122):
        raise SystemExit(f"{raw} is {im.size}, not a 1512x949 window capture")
    rgb = im.convert("RGB")
    top = composer_top(rgb)
    if top > COMPOSER_TOP:
        # The banner, then the composer some way below: shift everything
        # from the composer down by that much, then blank what it uncovered.
        below = rgb.crop((MAIN_X[0], top, MAIN_X[1], 2010))
        rgb.paste(BG, (MAIN_X[0], COMPOSER_TOP, MAIN_X[1], 2010))
        rgb.paste(below, (MAIN_X[0], COMPOSER_TOP))
    bullet = rgb.crop(BULLET)
    for i in range(ROWS):
        y = BULLET[1] - (BULLET_PITCH_FROM - i) * LIST_PITCH
        rgb.paste(SIDEBAR, (BULLET[0], y, BULLET[2], y + bullet.height))
        rgb.paste(bullet, (BULLET[0], y))
    rgb.putalpha(im.getchannel("A"))
    out = os.path.join(HERE, "base.png")
    rgb.save(out)
    print(out)


if __name__ == "__main__":
    main(sys.argv[1])
