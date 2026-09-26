#!/usr/bin/env python3
"""Word-level agreement between two transcript runs of the same items (WER of B against A,
case and punctuation ignored), plus the per-item differences."""
import json, re, sys
def words(s): return re.findall(r"[a-z0-9']+", s.lower().replace('’', "'"))
def wer(ref, hyp):
    r, h = words(ref), words(hyp)
    d = list(range(len(h) + 1))
    for i in range(1, len(r) + 1):
        prev, d[0] = d[0], i
        for j in range(1, len(h) + 1):
            cur = min(d[j] + 1, d[j - 1] + 1, prev + (r[i - 1] != h[j - 1]))
            prev, d[j] = d[j], cur
    return d[len(h)], len(r)
a = {o['id']: o for o in json.load(open(sys.argv[1]))}
b = {o['id']: o for o in json.load(open(sys.argv[2]))}
errs = tot = same = 0
diffs = []
for k in a:
    e, n = wer(a[k]['text'], b[k]['text'])
    errs += e; tot += n
    if e == 0: same += 1
    else: diffs.append((e, a[k]['text'], b[k]['text']))
print(f"{sys.argv[2].split('/')[-1]} vs {sys.argv[1].split('/')[-1]}: word differences {errs}/{tot} = {100 * errs / max(1, tot):.2f}%  identical words in {same}/{len(a)} items")
for e, x, y in sorted(diffs, key=lambda t: -t[0])[:int(sys.argv[3]) if len(sys.argv) > 3 else 0]:
    import difflib
    ops = [t for t in difflib.ndiff(words(x), words(y)) if t[0] in '+-']
    print(f"   {e:2}  {' '.join(ops)[:150]}")
