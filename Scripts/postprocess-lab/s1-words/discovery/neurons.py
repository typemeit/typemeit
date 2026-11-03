# Switch off the top-k "digits" neurons (zero their down_proj input) and score.
import os, sys, json, torch
sys.path.insert(0, os.path.dirname(__file__))
import ablate
from ablate import model, score
a = torch.load('attr.pt'); attr, plain = a['attr'], a['plain']
def top(k, plain_max):
    rows = sorted(((attr[l][n].item(), l, n) for l in attr for n in range(3072) if plain[l][n] <= plain_max), reverse=True)
    return rows[:k]
hooks = []
def mask(sel):
    for h in hooks: h.remove()
    hooks.clear()
    by = {}
    for _, l, n in sel: by.setdefault(l, []).append(n)
    for l, ns in by.items():
        idx = torch.tensor(ns)
        def f(mod, inp, idx=idx):
            x = inp[0].clone(); x[..., idx] = 0; return (x,)
        hooks.append(model.model.layers[l].mlp.down_proj.register_forward_pre_hook(f))
results = []
for spec in json.loads(sys.argv[1]):
    sel = top(spec['k'], spec.get('plain_max', 1e9))
    mask(sel)
    r = score(f"top{spec['k']} plain<={spec.get('plain_max','any')}"); r['neurons'] = [(l, n) for _, l, n in sel]
    results.append(r)
    print({k: v for k, v in r.items() if k not in ('samples', 'plain_diffs', 'neurons')}, flush=True)
json.dump(results, open(sys.argv[2], 'w'), indent=1)
