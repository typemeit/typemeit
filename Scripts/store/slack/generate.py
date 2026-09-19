#!/usr/bin/env python3
"""Fake the Slack DM for the App Store screenshot on top of a real capture.

    python3 Scripts/store/slack/generate.py            # writes out/slack.png

base.png is a 2x capture of Slack at 90% zoom (1 CSS px = 1.8 device px). The
constants below are pixel positions measured on that capture; re-measure them if
the base changes. Text is rendered with Slack's own Lato build in headless
Chrome at device scale 1.8, which reproduces the capture's rasterisation exactly.
Needs Google Chrome, Pillow and numpy.
"""
import os
import subprocess

import numpy as np
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out")
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
DSF = 1.8

# Measured on base.png (device px).
PANE = (710, 305, 3120, 1690)        # message pane: left, top, right, composer top
TOAST = (2471, 1693, 3150, 1872)     # "marked as read" toast, tiled over from column 2470
COMPOSER_X, COMPOSER_CAP = 771, 1807  # caret x and cap-height top of the composer text
CARET = (1800, 1832)
HEADER_TILE = (805, 170, 44)         # x, y, size of the channel avatar
HEADER_X, HEADER_CAP = 863, 180
WORKSPACE_TILE = (142, 161, 66)
WORKSPACE_X, WORKSPACE_CAP = 269, 181
WORKSPACE_CHEVRON = (424, 184, 444, 199)
DM_ROW = (270, 892, 660, 934)        # inside the selected sidebar pill, corners untouched
DM_TILE = (296, 899, 28)
DM_X, DM_CAP = 339, 903
OWN_TILE = (143, 1866, 64)           # own avatar in the rail
OWN_STATUS = (199, 1922)             # centre of the status cutout
RAIL = (55, 13, 59)
SIDEBAR = (85, 46, 90)
SIDEBAR_HEX = "#552e5a"
PILL = (247, 238, 254)
PILL_HEX = "#f7eefe"
INK = "#1d1c1d"
ACTIVE_GREEN = (43, 172, 118)
LAST_LINE_GAP = 26                   # device px between the last message and the composer

FONT = {400: "lato-regular", 700: "lato-bold", 900: "lato-black"}
FONTS_URL = "file://" + os.path.join(HERE, "fonts")
CSS = """
@font-face{font-family:L;src:url(%(fonts)s/lato-regular.woff2);font-weight:400}
@font-face{font-family:L;src:url(%(fonts)s/lato-bold.woff2);font-weight:700}
@font-face{font-family:L;src:url(%(fonts)s/lato-black.woff2);font-weight:900}
html,body{margin:0;background:#fff}
body{font-family:L,sans-serif;font-size:15px;line-height:22px;color:#1d1c1d;-webkit-font-smoothing:antialiased}
.pane{width:%(w)spx;padding-top:3px}
.msg{position:relative;padding:4px 20px 4px 64px;min-height:44px;box-sizing:border-box}
.msg.cont{padding:4px 20px 4px 64px;min-height:0}
.av{position:absolute;left:20px;top:8px;width:36px;height:36px;border-radius:4px;overflow:hidden}
.av img{width:36px;height:36px;display:block}
.hd{height:22px;white-space:nowrap}
.nm{font-weight:900}
.ts{font-size:12px;color:#616061;margin-left:8px}
.tx{white-space:pre-wrap}
.dv{position:relative;height:28px;margin:12px 0 8px;text-align:center}
.dv:before{content:'';position:absolute;left:0;right:0;top:14px;border-top:1px solid #ddd}
.dv span{position:relative;display:inline-flex;align-items:center;height:28px;padding:0 16px;border:1px solid #ddd;border-radius:24px;background:#fff;font-size:13px;font-weight:700;line-height:1;box-shadow:0 1px 3px rgba(0,0,0,.08)}
.dv svg{margin-left:10px}
"""
CHEVRON = ('<svg width="10" height="6" viewBox="0 0 10 6"><path d="M1 1l4 4 4-4" fill="none" '
           'stroke="#1d1c1d" stroke-width="1.5" stroke-linecap="round"/></svg>')


def chrome(html, out, w, h):
    path = os.path.join(OUT, "page.html")
    with open(path, "w") as f:
        f.write(html)
    subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars",
                    f"--force-device-scale-factor={DSF}", f"--window-size={w},{h}",
                    f"--screenshot={out}", f"file://{path}"], capture_output=True, check=True)
    return Image.open(out).convert("RGB")


def thread_html(msgs, avatars, width):
    parts = []
    for m in msgs:
        if "div" in m:
            parts.append(f'<div class=dv><span>{m["div"]}{CHEVRON}</span></div>')
        elif m.get("cont"):
            parts.append(f'<div class="msg cont"><div class=tx>{m["text"]}</div></div>')
        else:
            parts.append(f'<div class=msg><div class=av><img src="{avatars[m["name"]]}"></div>'
                         f'<div class=hd><span class=nm>{m["name"]}</span><span class=ts>{m["time"]}</span></div>'
                         f'<div class=tx>{m["text"]}</div></div>')
    return f"<!doctype html><meta charset=utf-8><style>{CSS % dict(w=width, fonts=FONTS_URL)}</style><div class=pane>{''.join(parts)}</div>"


def text(label, size, weight, color, bg):
    """Render one line; returns the image and the ink bbox."""
    html = (f'<!doctype html><meta charset=utf-8><style>@font-face{{font-family:L;src:url({FONTS_URL}/{FONT[weight]}.woff2)}}'
            f'html,body{{margin:0;background:{bg}}}.m{{position:absolute;left:5px;top:10px;font:{size}px/1.2 L;'
            f'color:{color};-webkit-font-smoothing:antialiased;white-space:nowrap}}</style><div class=m>{label}</div>')
    im = chrome(html, os.path.join(OUT, "text.png"), 600, 60)
    lum = np.array(im.convert("L")).astype(int)
    bg_lum = int(np.array(Image.new("RGB", (1, 1), bg).convert("L"))[0, 0])
    ys, xs = np.where(np.abs(lum - bg_lum) > 60)
    return im, (xs.min(), ys.min(), xs.max() + 1, ys.max() + 1)


def paste_text(dst, label, size, weight, color, bg, x, cap_top):
    im, (x0, y0, x1, y1) = text(label, size, weight, color, bg)
    dst.paste(im.crop((x0 - 2, y0 - 3, x1 + 2, y1 + 3)), (x - 2, cap_top - 3))
    return x + (x1 - x0)


def tile(dst, path, x, y, size, radius):
    """Rounded avatar tile, composited at 4x so the corners are anti-aliased."""
    s = 4
    av = Image.open(path).convert("RGB").resize((size * s, size * s), Image.LANCZOS)
    mask = Image.new("L", (size * s, size * s), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size * s - 1, size * s - 1), radius=radius * s, fill=255)
    bg = dst.crop((x, y, x + size, y + size)).resize((size * s, size * s), Image.LANCZOS)
    bg.paste(av, (0, 0), mask)
    dst.paste(bg.resize((size, size), Image.LANCZOS), (x, y))


def avatar(name, colour):
    """A tinted cloud render on off-white, cropped to a square."""
    path = os.path.join(OUT, f"avatar-{name}.png")
    cloud = Image.open(os.path.join(HERE, "clouds", f"{colour}.png")).convert("RGBA").resize((290, 290), Image.LANCZOS)
    im = Image.new("RGBA", (240, 240), "#F4F4F2")
    im.alpha_composite(cloud, (-25, -25))
    im.convert("RGB").save(path)
    return path


def own_avatar(dst, path):
    x, y, size = OWN_TILE
    s = 4
    big = Image.new("RGB", (size * s, size * s), RAIL)
    av = Image.open(path).convert("RGB").resize((size * s, size * s), Image.LANCZOS)
    mask = Image.new("L", (size * s, size * s), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size * s - 1, size * s - 1), radius=8 * s, fill=255)
    big.paste(av, (0, 0), mask)
    d = ImageDraw.Draw(big)
    cx, cy = (OWN_STATUS[0] - x) * s, (OWN_STATUS[1] - y) * s
    d.ellipse((cx - 14.5 * s, cy - 14.5 * s, cx + 14.5 * s, cy + 14.5 * s), fill=RAIL)
    d.ellipse((cx - 7.5 * s, cy - 7.5 * s, cx + 7.5 * s, cy + 7.5 * s), fill=ACTIVE_GREEN)
    ImageDraw.Draw(dst).rectangle((x - 3, y - 3, x + size + 3, y + size + 3), fill=RAIL)
    dst.paste(big.resize((size, size), Image.LANCZOS), (x, y))


def generate(msgs, composer, other, me, workspace, avatars, out_path):
    os.makedirs(OUT, exist_ok=True)
    src = Image.open(os.path.join(HERE, "base.png")).convert("RGB")
    a = np.array(src)
    x0, y0, x1, y1 = TOAST
    a[y0:y1, x0:x1 - 64] = a[y0:y1, x0 - 1:x0]
    a[y0:y1, x1 - 64:x1] = a[y1 + 8:y1 + 9, x1 - 64:x1]
    src = Image.fromarray(a)
    d = ImageDraw.Draw(src)

    # Message pane, bottom-aligned above the composer and clipped at the tab bar.
    left, top, right, composer_top = PANE
    width = int((right - left) / DSF)
    thread = chrome(thread_html(msgs, avatars, width), os.path.join(OUT, "thread.png"), width, 1000)
    d.rectangle((left, top, right, composer_top - 2), fill=(255, 255, 255))
    ink_rows = np.where((np.array(thread.convert("L")) < 160).sum(axis=1) > 0)[0]
    last = ink_rows.max()
    y = composer_top - LAST_LINE_GAP - last
    clip = max(0, top - y)
    src.paste(thread.crop((0, clip, thread.width, last + 4)), (left, y + clip))

    # Composer: typed text with a caret after it.
    d.rectangle((COMPOSER_X - 12, 1790, 2400, 1848), fill=(255, 255, 255))
    end = paste_text(src, composer, 15, 400, INK, "#fff", COMPOSER_X, COMPOSER_CAP)
    d.rectangle((end + 6, CARET[0], end + 7, CARET[1]), fill=(28, 28, 28))

    # Channel header.
    hx, hy, hs = HEADER_TILE
    d.rectangle((hx - 6, 163, 1300, 222), fill=(255, 255, 255))
    tile(src, avatars[other], hx, hy, hs, 7)
    paste_text(src, other, 18, 900, INK, "#fff", HEADER_X, HEADER_CAP)

    # Workspace name and tile.
    chevron = src.crop(WORKSPACE_CHEVRON).copy()
    d.rectangle((WORKSPACE_X - 7, 172, 460, 215), fill=SIDEBAR)
    end = paste_text(src, workspace, 18, 900, "#ffffff", SIDEBAR_HEX, WORKSPACE_X, WORKSPACE_CAP)
    src.paste(chevron, (end + 17, WORKSPACE_CHEVRON[1]))
    tile(src, avatars["workspace"], *WORKSPACE_TILE, 8)

    # Selected DM row in the sidebar.
    d.rectangle(DM_ROW, fill=PILL)
    tile(src, avatars[other], *DM_TILE, 5)
    paste_text(src, other, 15, 400, "#340a38", PILL_HEX, DM_X, DM_CAP)

    own_avatar(src, avatars[me])
    src.save(out_path)
    return out_path


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    avatars = {"Sam": avatar("sam", "coral"), "Max": avatar("max", "sky"), "workspace": avatar("workspace", "black")}
    S = lambda t, x: dict(name="Sam", time=t, text=x)
    M = lambda t, x: dict(name="Max", time=t, text=x)
    C = lambda x: dict(cont=True, text=x)
    D = lambda x: dict(div=x)
    msgs = [
        S("5:58 PM", "no rush, tomorrow is fine"),
        D("Yesterday"),
        M("9:04 AM", "morning, deck is in the folder"),
        S("9:31 AM", "looks good"), C("swapped the chart on slide 6, the old one was hard to read"),
        M("9:33 AM", "cheers, that's much better"),
        S("4:52 PM", "are you around for the 10am tomorrow?"),
        M("4:55 PM", "yeah, I'll be in"),
        D("Today"),
        S("12:10 PM", "how did it go"),
        M("12:41 PM", "fine I think, they had a lot of questions about pricing"), C("sending the follow-up this afternoon"),
        S("5:41 PM", "what time are you done today"),
        M("5:42 PM", "should be out by six"),
        S("5:42 PM", "nice, dinner at mine?"), C("I'll cook if you bring something"),
    ]
    print(generate(msgs, "leaving in ten, I'll grab a bottle of red on the way over",
                   other="Sam", me="Max", workspace="type me it", avatars=avatars,
                   out_path=os.path.join(OUT, "slack.png")))
