#!/usr/bin/env python3
"""Compares replays of real dictations: latency, model calls, and every output
that differs from the reference run.
usage: histdiff.py out/<reference> out/<variant> [more variants...]"""
import json, os, sys, difflib


def pct(xs, q):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(len(xs) * q))] if xs else 0


def load(d):
    return json.load(open(os.path.join(d, 'result.json')))


ref = load(sys.argv[1])
for d in sys.argv[1:]:
    rs = load(d)
    ms = [r['ms'] for r in rs]
    print(f"{os.path.basename(d):28} model applied {sum(r['applied'] for r in rs):3}/{len(rs)}   "
          f"p50 {pct(ms, .5):5.0f}  p90 {pct(ms, .9):5.0f}  p95 {pct(ms, .95):5.0f}  mean {sum(ms) / len(ms):5.0f} ms")
for d in sys.argv[2:]:
    rs = load(d)
    diffs = [(a, b) for a, b in zip(ref, rs) if a['output'] != b['output']]
    print(f"\n== {os.path.basename(d)}: {len(diffs)} of {len(rs)} outputs differ from {os.path.basename(sys.argv[1])}")
    for a, b in diffs:
        ops = [t for t in difflib.ndiff(a['output'].split(), b['output'].split()) if t[0] in '+-']
        print(f"  [{'model' if b['applied'] else 'code '}] {' '.join(ops)[:170]}")
