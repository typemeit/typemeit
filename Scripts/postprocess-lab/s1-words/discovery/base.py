import os, sys, json, re, time, torch
sys.path.insert(0, os.path.dirname(__file__))
from s1 import tok, model, prompt
cases = json.load(open(os.path.join(os.path.dirname(__file__), '../../../cleanup-eval/cases.json')))
inputs = sorted({c['input'] for c in cases})
BAN = [[220]] + [[i] for i in range(15, 25)]
@torch.no_grad()
def gen(t, ban=False):
    ids = tok(prompt(t), return_tensors="pt")
    kw = dict(bad_words_ids=BAN) if ban else {}
    out = model.generate(**ids, max_new_tokens=int(len(t.split())*1.8)+32, do_sample=False, **kw)
    return tok.decode(out[0][ids.input_ids.shape[1]:], skip_special_tokens=True).strip()
res = []
t0 = time.time()
for t in inputs:
    res.append({'input': t, 'base': gen(t), 'ban': gen(t, True) if not re.search(r'\d', t) else None})
print(f'{len(inputs)} inputs in {time.time()-t0:.0f}s', file=sys.stderr)
json.dump(res, open('base-outputs.json', 'w'), indent=1)
