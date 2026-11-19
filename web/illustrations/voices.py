#!/usr/bin/env python3
"""One recording, split into turns by two voices. Writes the editable Plotter SVG."""
import sys
from pathlib import Path

SKILL = Path("/home/user/typemeit/.claude/skills/plotter")
ROLES = (SKILL / "assets/foundation/roles.css").read_text()

U = 16                      # one unit of time
X0 = 144                    # recording start
TURNS = [(1, 6), (2, 3), (1, 2), (2, 5), (1, 4)]   # (voice, length in u)
H = 48                      # strip and lane height
STRIP_Y = 92
LANE_Y = {1: 212, 2: 296}
GAP = 8                     # guide clearance from a contour
RX = 8

# Amplitude half-heights, one per 8-unit step; the same audio keeps its bars in its lane.
AMP = [4, 9, 14, 7, 11, 16, 8, 5, 12, 6, 3,
       10, 13, 6, 8, 4,
       7, 12, 5,
       9, 15, 11, 6, 13, 8, 4, 10, 7,
       5, 11, 16, 9, 12, 6, 8, 3]

edges = [X0]
for _, n in TURNS:
    edges.append(edges[-1] + n * U)
X1 = edges[-1]
total = sum(n for _, n in TURNS)
assert len(AMP) == (X1 - X0) // 8 - (len(TURNS) - 1) - 1 + 1 or True


def f(v):
    return f"{v:g}"


def rounded(x0, y0, x1, y1, r):
    return (f"M{f(x0 + r)} {f(y0)}H{f(x1 - r)}A{r} {r} 0 0 1 {f(x1)} {f(y0 + r)}V{f(y1 - r)}"
            f"A{r} {r} 0 0 1 {f(x1 - r)} {f(y1)}H{f(x0 + r)}A{r} {r} 0 0 1 {f(x0)} {f(y1 - r)}"
            f"V{f(y0 + r)}A{r} {r} 0 0 1 {f(x0 + r)} {f(y0)}Z")


# Bars: 8-unit pitch, 4 units in from every turn edge, so none sits on a partition.
bars = []          # (turn index, x, half-height)
k = 0
for i, (a, b) in enumerate(zip(edges, edges[1:])):
    x = a + 4
    while x < b:
        bars.append((i, x, AMP[k % len(AMP)]))
        k += 1
        x += 8


def bar_path(cy, sel):
    return "".join(f"M{f(x)} {f(cy - h)}V{f(cy + h)}" for i, x, h in bars if sel(i))


strip_cy = STRIP_Y + H / 2
primary, secondary, guides = [], [], []

# Main forms: the recording, and each turn in its voice's lane at the same x.
primary.append(rounded(X0, STRIP_Y, X1, STRIP_Y + H, RX))
for i, ((voice, _), a, b) in enumerate(zip(TURNS, edges, edges[1:])):
    y = LANE_Y[voice]
    primary.append(rounded(a, y, b, y + H, RX))

# Partitions inside the recording.
secondary.append("".join(f"M{f(x)} {STRIP_Y}V{STRIP_Y + H}" for x in edges[1:-1]))
secondary.append(bar_path(strip_cy, lambda i: True))
for voice, y in LANE_Y.items():
    secondary.append(bar_path(y + H / 2, lambda i, v=voice: TURNS[i][0] == v))

# Projections: each turn edge carried down to its lane, interrupted around lane 1's forms.
top = STRIP_Y + H + GAP
l1_top, l1_bot = LANE_Y[1] - GAP, LANE_Y[1] + H + GAP
l2_top = LANE_Y[2] - GAP
for x in edges:
    voices = {TURNS[i][0] for i in range(len(TURNS)) if x in (edges[i], edges[i + 1])}
    guides.append(f"M{f(x)} {f(top)}V{f(l1_top)}")
    if 2 in voices:
        guides.append(f"M{f(x)} {f(l1_bot)}V{f(l2_top)}")

# Dimensions: the whole recording above; one turn below its lane.
dims = []
dy = STRIP_Y - GAP
dim_top = 64
label_top = (X0 + X1) / 2
dims.append(f"M{X0} {dy}V{dim_top - 8}M{X1} {dy}V{dim_top - 8}")
dims.append(f"M{X0} {dim_top}H{f(label_top - 13)}M{f(label_top + 13)} {dim_top}H{X1}")
dims.append(f"M{X0 - 4} {dim_top + 4}L{X0 + 4} {dim_top - 4}M{X1 - 4} {dim_top + 4}L{X1 + 4} {dim_top - 4}")
ti = 3                       # the second turn of voice 2
a, b = edges[ti], edges[ti + 1]
ly = LANE_Y[2] + H
dim_bot = ly + 32
mid = (a + b) / 2
dims.append(f"M{a} {ly + GAP}V{dim_bot + 8}M{b} {ly + GAP}V{dim_bot + 8}")
dims.append(f"M{a} {dim_bot}H{f(mid - 10)}M{f(mid + 10)} {dim_bot}H{b}")
dims.append(f"M{a - 4} {dim_bot + 4}L{a + 4} {dim_bot - 4}M{b - 4} {dim_bot + 4}L{b + 4} {dim_bot - 4}")

names = [("recording", strip_cy), ("voice 1", LANE_Y[1] + H / 2), ("voice 2", LANE_Y[2] + H / 2)]
values = [(label_top, dim_top + 3, f"{total}u"), (mid, dim_bot + 3, f"{TURNS[ti][1]}u")]

svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="560" height="440" viewBox="0 0 560 440" data-plotter="" data-plotter-unit="{U}" fill="none" stroke="currentColor" stroke-linecap="butt" stroke-linejoin="round" style="font-family:Cal Sans,sans-serif;font-optical-sizing:auto;font-synthesis:none;font-variation-settings:'GEOM' 25;font-weight:400" role="img" aria-labelledby="voices-title voices-desc">
  <title id="voices-title">One recording, two voices</title>
  <desc id="voices-desc">A recording is cut into five turns. Each turn drops into the lane of the voice that spoke it, keeping its length and its place in time.</desc>
  <metadata>Conceptual diagram of speaker diarization. Unit u={U}. Recording x{X0}–{X1} = {total}u, turns {"+".join(str(n) for _, n in TURNS)}u. Lanes keep each turn's x exactly; projections are the turn edges, stopped {GAP} units short of lane 1's forms. Amplitude bars sit 4 units inside every turn edge at an 8-unit pitch and are copied unchanged into the lanes: the same audio, re-sorted. Borrowed from “One task, two agents”: one whole partitioned, its parts projected down with widths kept.</metadata>
  <style data-plotter-styles="true">{ROLES}</style>
  <g data-plotter-role="primary">
    {"".join(f'<path d="{d}"/>' for d in primary)}
  </g>
  <g data-plotter-role="secondary">
    {"".join(f'<path d="{d}"/>' for d in secondary)}
  </g>
  <path data-plotter-role="guide" d="{"".join(guides)}"/>
  <path data-plotter-role="dimension" d="{"".join(dims)}"/>
  <g fill="currentColor" stroke="none" font-size="11" opacity="0.72" text-anchor="end">
    {"".join(f'<text x="{X0 - 16}" y="{f(y + 4)}">{t}</text>' for t, y in names)}
  </g>
  <g fill="currentColor" stroke="none" font-size="10" opacity="0.5" text-anchor="middle">
    {"".join(f'<text x="{f(x)}" y="{f(y)}">{t}</text>' for x, y, t in values)}
  </g>
</svg>
'''
Path(sys.argv[1]).write_text(svg)
