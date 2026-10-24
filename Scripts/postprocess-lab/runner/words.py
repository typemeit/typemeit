#!/usr/bin/env python3
"""Re-scores eval runs on words alone: the eval's own normalisation (case and
punctuation ignored) with line breaks ignored too and exact cases relaxed.
usage: words.py out/<name> [out/<name2> ...]"""
import json, os, re, sys


def words(s):
    return re.split(r'[^\w$£€%"]+|_', s.lower())


def norm(s):
    return [w for w in words(s) if w]


def passes(r):
    return r['pass'] or any(norm(r['output']) == norm(e) for e in r['expected'])


for d in sys.argv[1:]:
    rs = json.load(open(os.path.join(d, 'result.json')))
    normal = [r for r in rs if r.get('wish') is None]
    wishes = [r for r in rs if r.get('wish') is not None]
    print(f"{os.path.basename(d.rstrip('/')):24} eval {sum(r['pass'] for r in normal)}/{len(normal)}"
          f"  words only {sum(passes(r) for r in normal)}/{len(normal)}"
          f"   wishes {sum(r['pass'] for r in wishes)}/{len(wishes)}  words only {sum(passes(r) for r in wishes)}/{len(wishes)}")
