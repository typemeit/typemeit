"""Headless-Chrome text rendering for the painted scenes (slack, claude).

Each scene makes one Painter with its scratch directory, the device scale
that reproduces its app's rasterisation, and a page width wide enough for
its longest line, then pastes lines set in its app's own font onto the base.
Needs Google Chrome, Pillow and numpy.
"""
import os
import subprocess

import numpy as np
from PIL import Image

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
TEXT_PAGE_HEIGHT = 60
# A pixel is ink when its luminance differs from the background's by more than this.
INK_THRESHOLD = 60


class Painter:
    def __init__(self, out_dir, dsf, text_width):
        self.out_dir, self.dsf, self.text_width = out_dir, dsf, text_width

    def chrome(self, html, out, w, h):
        path = os.path.join(self.out_dir, "page.html")
        with open(path, "w") as f:
            f.write(html)
        subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars",
                        f"--force-device-scale-factor={self.dsf}", f"--window-size={w},{h}",
                        f"--screenshot={out}", f"file://{path}"], capture_output=True, check=True)
        return Image.open(out).convert("RGB")

    def text(self, label, font_url, size, color, bg):
        """Render one line in the font at font_url; returns the image and the ink bbox."""
        html = (f'<!doctype html><meta charset=utf-8><style>@font-face{{font-family:F;src:url({font_url})}}'
                f'html,body{{margin:0;background:{bg}}}.m{{position:absolute;left:5px;top:10px;font:{size}px/1.2 F;'
                f'color:{color};-webkit-font-smoothing:antialiased;white-space:nowrap}}</style><div class=m>{label}</div>')
        im = self.chrome(html, os.path.join(self.out_dir, "text.png"), self.text_width, TEXT_PAGE_HEIGHT)
        lum = np.array(im.convert("L")).astype(int)
        bg_lum = int(np.array(Image.new("RGB", (1, 1), bg).convert("L"))[0, 0])
        ys, xs = np.where(np.abs(lum - bg_lum) > INK_THRESHOLD)
        return im, (xs.min(), ys.min(), xs.max() + 1, ys.max() + 1)

    def paste_text(self, dst, label, font_url, size, color, bg, x, cap_top, clip=None):
        """Paste one line with its ink starting at x and its cap height at cap_top, cut off at
        clip (right, bottom) if given; returns the x where the ink ends."""
        im, (x0, y0, x1, y1) = self.text(label, font_url, size, color, bg)
        piece = im.crop((x0 - 2, y0 - 3, x1 + 2, y1 + 3))
        if clip is not None:
            piece = piece.crop((0, 0, min(piece.width, clip[0] - (x - 2)), min(piece.height, clip[1] - (cap_top - 3))))
        dst.paste(piece, (x - 2, cap_top - 3))
        return x + (x1 - x0)
