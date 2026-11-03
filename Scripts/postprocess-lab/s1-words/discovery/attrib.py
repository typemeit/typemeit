# Which MLP neurons push "digits" over "the spoken word" at the decision token?
import os, sys, json, torch
sys.path.insert(0, os.path.dirname(__file__))
from s1 import tok, model, prompt
from collect import WORD_IDS, DIGIT_IDS
torch.set_grad_enabled(True)
for p in model.parameters(): p.requires_grad_(False)
L = range(8, 28)
acts = {}
def cap(l):
    def f(mod, inp):
        a = inp[0]; a.requires_grad_(True); a.retain_grad(); acts[l] = a
    return f
hs = [model.model.layers[l].mlp.down_proj.register_forward_pre_hook(cap(l)) for l in L]
data = json.load(open('synth.json'))['train']
widx = torch.tensor(sorted(WORD_IDS))
attr = {l: torch.zeros(3072) for l in L}; plainact = {l: torch.zeros(3072) for l in L}
ndec = nplain = 0
for t in data:
    p = tok(prompt(t), return_tensors="pt").input_ids
    with torch.no_grad(): g = model.generate(p, max_new_tokens=60, do_sample=False)
    ids = g[0].tolist()
    dec = [i for i in range(p.shape[1]-1, len(ids)-1) if (ids[i+1] == 220 or ids[i+1] in DIGIT_IDS) and ids[i] != 220 and ids[i] not in DIGIT_IDS]
    plain = [i for i in range(p.shape[1]-1, len(ids)-1) if i not in dec and ids[i+1] not in DIGIT_IDS and ids[i+1] != 220 and ids[i] != 220 and ids[i] not in DIGIT_IDS]
    logits = model(g).logits[0]
    if dec:
        lg = logits[dec]
        diff = lg[torch.arange(len(dec)), torch.tensor([ids[i+1] for i in dec])] - lg[:, widx].max(1).values
        diff.sum().backward()
        for l in L:
            attr[l] += (acts[l][0, dec] * acts[l].grad[0, dec]).sum(0).detach()
        ndec += len(dec)
    for l in L:
        plainact[l] += acts[l][0, plain].detach().abs().sum(0)
    nplain += len(plain)
    model.zero_grad(set_to_none=True)
torch.save({'attr': {l: attr[l]/ndec for l in L}, 'plain': {l: plainact[l]/nplain for l in L}}, 'attr.pt')
rows = [(attr[l][n].item()/ndec, l, n, plainact[l][n].item()/nplain) for l in L for n in range(3072)]
rows.sort(reverse=True)
print('decision positions', ndec, 'plain positions', nplain)
print('total attribution', sum(r[0] for r in rows))
for r in rows[:30]: print(f'L{r[1]:2d} n{r[2]:4d} attr={r[0]:7.3f} plain|act|={r[3]:.3f}')
import collections; c = collections.Counter(r[1] for r in rows[:128]); print('top128 by layer', sorted(c.items()))
