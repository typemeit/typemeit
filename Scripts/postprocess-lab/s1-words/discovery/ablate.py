import os, sys, json, re, torch
sys.path.insert(0, os.path.dirname(__file__))
from s1 import tok, model, prompt
acts = torch.load('acts.pt'); D, W = acts['D'].float(), acts['W'].float()
synth = json.load(open('synth.json'))['heldout']
base = json.load(open('base-outputs.json'))
evalnum = [x['input'] for x in base if x['ban'] is not None and re.search(r'\d', x['base'])]
plain = [x for x in base if x['ban'] is not None and not re.search(r'\d', x['base'])][:40]
FILL = {"um", "uh", "er", "erm", "ah", "umm", "uhh"}
def words(s): return [w for w in re.sub(r"[^a-z0-9' ]", " ", s.lower().replace("-", " ")).split() if w not in FILL]
def recall(i, o):
    ow = set(words(o)); iw = words(i)
    return sum(w in ow for w in iw) / max(1, len(iw))
hooks = []
def set_ablation(u, layers):
    for h in hooks: h.remove()
    hooks.clear()
    if u is None: return
    def f(mod, inp, out):
        h = out[0] if isinstance(out, tuple) else out
        h = h - (h @ u)[..., None] * u
        return (h,) + tuple(out[1:]) if isinstance(out, tuple) else h
    for l in layers: hooks.append(model.model.layers[l].register_forward_hook(f))
@torch.no_grad()
def gen(t):
    p = tok(prompt(t), return_tensors="pt").input_ids
    g = model.generate(p, max_new_tokens=int(len(t.split())*1.8)+32, do_sample=False)
    return tok.decode(g[0][p.shape[1]:], skip_special_tokens=True).strip()
def score(name):
    r = {'name': name}
    so = [gen(t) for t in synth]; eo = [gen(t) for t in evalnum]; po = [gen(x['input']) for x in plain]
    alln = list(zip(synth + evalnum, so + eo))
    r['digits'] = sum(bool(re.search(r'\d', o)) for _, o in alln)
    r['nonascii'] = sum(bool(re.search(r'[^\x00-\x7f]', o)) for _, o in alln)
    r['recall'] = round(sum(recall(i, o) for i, o in alln) / len(alln), 3)
    r['plain_changed'] = sum(o != x['base'] for o, x in zip(po, plain))
    r['n'] = len(alln); r['plain_n'] = len(plain)
    r['samples'] = [(i, o) for i, o in alln[-21:]]
    r['plain_diffs'] = [(x['base'], o) for o, x in zip(po, plain) if o != x['base']]
    return r
if __name__ == '__main__':
    configs = json.loads(sys.argv[1])
    results = []
    for c in configs:
        if c['dir'] is None: set_ablation(None, [])
        else:
            l = c['dir']; r = D[:, l].mean(0) - W[:, l].mean(0); u = r / r.norm()
            set_ablation(u, range(c['from'], c.get('to', 28)))
        res = score(c['name']); results.append(res)
        print({k: v for k, v in res.items() if k not in ('samples', 'plain_diffs')}, flush=True)
    json.dump(results, open(sys.argv[2], 'w'), indent=1)
