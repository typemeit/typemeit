import os, sys, json, torch
sys.path.insert(0, os.path.dirname(__file__))
from s1 import tok, model, prompt
words = "one two three four five six seven eight nine ten eleven twelve twenty thirty forty fifty sixty seventy eighty ninety hundred thousand million half quarter".split()
WORD_IDS = {tok.encode(" " + w)[0] for w in words if len(tok.encode(" " + w)) == 1} | {tok.encode(w.capitalize())[0] for w in words if len(tok.encode(w.capitalize())) == 1}
DIGIT_IDS = set(range(15, 25))
data = json.load(open('synth.json'))['train']
D, W, outs = [], [], []
with torch.no_grad():
    for t in data:
        p = tok(prompt(t), return_tensors="pt").input_ids
        g = model.generate(p, max_new_tokens=60, do_sample=False)
        outs.append(tok.decode(g[0][p.shape[1]:], skip_special_tokens=True).strip())
        hs = model(g, output_hidden_states=True).hidden_states  # 29 x [1, T, 1024]
        ids = g[0].tolist()
        for i in range(p.shape[1] - 1, len(ids) - 1):
            nxt, prev = ids[i + 1], ids[i]
            h = torch.stack([x[0, i] for x in hs])  # [29, 1024]
            if (nxt == 220 or nxt in DIGIT_IDS) and prev != 220 and prev not in DIGIT_IDS:
                D.append(h)
            elif nxt in WORD_IDS:
                W.append(h)
D, W = torch.stack(D), torch.stack(W)
torch.save({'D': D, 'W': W}, 'acts.pt')
json.dump(outs, open('train-outputs.json', 'w'), indent=1)
print('digit positions', len(D), 'word positions', len(W))
