#!/usr/bin/env python3
"""Term-level score of a boosted run on the vocabulary clips: fixes (term expected,
boost has it, plain lacks it), false positives (boost adds a term the expected
text lacks), misses (term expected, boost lacks it)."""
import json, re, sys
S = sys.argv[1]
items = {i['id']: i for i in json.load(open(f'{S}/fluid/sets/eval-vocab-items.json'))}
plain = {o['id']: o['text'] for o in json.load(open(f'{S}/fluid/out/eval-int8-plain.json'))}
expected = {}
for r in json.load(open(f'{S}/runner/out/baseline-cold/result.json')):
    expected.setdefault(r['input'], r['expected'][0])
def letters(s): return re.sub(r'[^a-z0-9]', '', s.lower())
def has(text, term):
    t = letters(term)
    words = re.findall(r"[\w.'’-]+", text)
    joined = [letters(w) for w in words]
    return any(t == w for w in joined) or any(t == ''.join(joined[i:i + n]) for n in (2, 3) for i in range(len(joined)))
for run in sys.argv[2:]:
    boost = {o['id']: o for o in json.load(open(f'{S}/fluid/out/{run}.json'))}
    fixes, fps, misses = [], [], []
    for k, i in items.items():
        exp = expected[i['input']]
        for term in i['vocab']:
            e, b, p = has(exp, term), has(boost[k]['text'], term), has(plain[k], term)
            if e and b and not p: fixes.append(term)
            if b and not e: fps.append(f"{term} in '{boost[k]['text'][:60]}'")
            if e and not b: misses.append(term)
    ms = sorted(o['ms'] for o in boost.values())
    print(f"{run:28} fixes {len(fixes):2}  false positives {len(fps)}  misses {len(misses)}  p50 {ms[len(ms)//2]:.0f} ms")
    for fp in fps: print(f"{'':30}FP: {fp}")
