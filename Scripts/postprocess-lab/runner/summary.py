#!/usr/bin/env python3
"""Summarise one or more eval runs: pass counts, wishes, latency by input length.
usage: summary.py out/<name> [out/<name2> ...]   (a second run is diffed against the first)"""
import json, sys, os

def pct(xs, q):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(len(xs) * q))] if xs else 0

def load(d):
    return json.load(open(os.path.join(d, 'result.json')))

def key(r):
    return (r['input'], tuple(r['styles']), r.get('wish') is not None, bool(r.get('screen')))

def summarise(d):
    rs = load(d)
    normal = [r for r in rs if r.get('wish') is None]
    wishes = [r for r in rs if r.get('wish') is not None]
    ms = [r['ms'] for r in rs]
    print(f"== {os.path.basename(d.rstrip('/'))}")
    print(f"   eval {sum(r['pass'] for r in normal)}/{len(normal)}   wishes {sum(r['pass'] for r in wishes)}/{len(wishes)}   model applied {sum(r['applied'] for r in rs)}/{len(rs)}")
    print(f"   latency ms  p50 {pct(ms,.5):.0f}  p90 {pct(ms,.9):.0f}  p95 {pct(ms,.95):.0f}  max {max(ms):.0f}  mean {sum(ms)/len(ms):.0f}  total {sum(ms)/1000:.0f} s")
    buckets = {}
    for r in rs:
        n = len(r['input'].split())
        b = '1-5w' if n <= 5 else '6-15w' if n <= 15 else '16-40w' if n <= 40 else '41+w'
        buckets.setdefault(b, []).append(r['ms'])
    print('   ' + '  '.join(f"{b}: n={len(buckets[b])} p50={pct(buckets[b], .5):.0f}" for b in ['1-5w', '6-15w', '16-40w', '41+w'] if b in buckets))
    return rs

runs = [summarise(d) for d in sys.argv[1:]]
if len(runs) >= 2:
    a = {key(r): r for r in runs[0]}
    for rs, d in zip(runs[1:], sys.argv[2:]):
        print(f"\n-- changes vs {os.path.basename(sys.argv[1].rstrip('/'))} in {os.path.basename(d.rstrip('/'))}")
        for r in rs:
            o = a.get(key(r))
            if o is None or o['pass'] == r['pass']:
                continue
            tag = ('WISH ' if r.get('wish') else '') + ('now passes' if r['pass'] else 'now FAILS')
            print(f"   {tag}: {r['input'][:90]} {list(r['styles'])}")
            if not r['pass']:
                print(f"      got:      {r['output'][:200]}")
                print(f"      expected: {r['expected'][0][:200]}")
