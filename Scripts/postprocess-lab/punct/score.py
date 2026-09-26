#!/usr/bin/env python3
"""Scores restored punctuation against real Parakeet punctuation, word-aligned."""
import json, re, sys, difflib
S = sys.argv[1]
bench = json.load(open(f'{S}/punct/bench.json'))
def toks(t):
    out = []
    for w in t.split():
        core = re.sub(r"[^\w']", '', w.lower())
        if not core: continue
        m = re.search(r'[.?!,;:]+$', w)
        out.append((core, (m.group(0)[-1] if m else ''), w[:1].isupper()))
    return out
def score(name, hyps):
    tp = {'end': 0, 'comma': 0, 'q': 0}; fp = dict(tp); fn = dict(tp); case_ok = case_n = changed = total = 0
    for b, h in zip(bench, hyps):
        r, y = toks(b['ref']), toks(h)
        sm = difflib.SequenceMatcher(a=[x[0] for x in r], b=[x[0] for x in y], autojunk=False)
        total += len(r)
        changed += sum(max(i2 - i1, j2 - j1) for op, i1, i2, j1, j2 in sm.get_opcodes() if op != 'equal')
        for op, i1, i2, j1, j2 in sm.get_opcodes():
            if op != 'equal': continue
            for k in range(i2 - i1):
                ri, yi = r[i1 + k], y[j1 + k]
                last = (i1 + k == len(r) - 1)
                for kind, marks in (('end', '.?!'), ('comma', ',;:'), ('q', '?')):
                    if last and kind != 'comma': continue
                    a, c = ri[1] in marks and ri[1] != '', yi[1] in marks and yi[1] != ''
                    tp[kind] += a and c; fp[kind] += (not a) and c; fn[kind] += a and not c
                if ri[0] != 'i': case_n += 1; case_ok += ri[2] == yi[2]
    f1 = lambda k: 2 * tp[k] / max(1, 2 * tp[k] + fp[k] + fn[k])
    print(f"{name:16} sentence-end F1 {f1('end'):.2f} (P {tp['end']/max(1,tp['end']+fp['end']):.2f} R {tp['end']/max(1,tp['end']+fn['end']):.2f})  comma F1 {f1('comma'):.2f}  question F1 {f1('q'):.2f}  casing {case_ok/max(1,case_n):.3f}  words changed {100*changed/max(1,total):.1f}%")
for m in ['pcs', 'sherpa']:
    mp = json.load(open(f'{S}/punct/map-bench-{m}.json'))
    score(m, [mp[b['input']] for b in bench])
apple = json.load(open(f'{S}/runner/out/bench-apple/result.json'))
score('apple model', [r['output'] for r in apple])
score('no punctuation', [b['input'] for b in bench])
