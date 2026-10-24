"""Zero-padded against tiled clips (emb.py EMBED=pad / tile), extracted to out/pad and out/tile.

How alike the two embeddings of one clip are, by clip length; then the app's gradient descent
(naming.py's GD) naming each call from the others, with strangers, for pad, tile, and a library
learned padded asked about tiled clips (what an unmigrated VoiceLibrary would do).
"""
import json, glob, os, numpy as np
rows = json.load(open('out/pad/rows.json')); assert rows == json.load(open('out/tile/rows.json'))
P = np.load('out/pad/vecs.npy'); T = np.load('out/tile/vecs.npy')
P /= np.linalg.norm(P, axis=1, keepdims=True); T /= np.linalg.norm(T, axis=1, keepdims=True)
dur = np.array([r['dur'] for r in rows]); cos = (P * T).sum(1)
for lo, hi in [(1.5, 2), (2, 3), (3, 4), (4, 6), (6, 9.99), (9.99, 11)]:
    sel = (dur >= lo) & (dur < hi)
    print(f"{lo:>5}-{hi:<5}s n={sel.sum():5d} cosine(pad, tile) p10/50/90 {np.percentile(cos[sel], [10, 50, 90]).round(3)}")

ROOT = os.path.expanduser('~/Library/Application Support/TypeMeIt/Meetings')
names, seen = {}, set()  # as naming.py
for f in sorted(glob.glob(f'{ROOT}/2026-*')):
    g = os.path.basename(f)[:15]
    if g in seen or not os.path.exists(f'{f}/meeting.json'): continue
    m = json.load(open(f'{f}/meeting.json'))
    if m['kind'] != 'call' or not m.get('tracks'): continue
    seen.add(g)
    for s in m['speakers']:
        if s['isYou']: names[(g, s['id'])] = 'You'
        elif s.get('nameSource') and s['name'] not in ('Them', 'You'): names[(g, s['id'])] = s['name']
kind = np.array([r['kind'] for r in rows]); meeting = np.array([r['meeting'] for r in rows]); speaker = np.array([r['speaker'] for r in rows])
person = np.array([names.get((r['meeting'], r['speaker']), '') for r in rows])
usable = (person != '') & np.isin(kind, ['you', 'far', 'echo', 'room'])

def gd(Xt, yt, steps=300, rate=4.0, momentum=0.9):
    """naming.py's GD: what the app runs."""
    classes, y = np.unique(yt, return_inverse=True); N, D = Xt.shape; K = len(classes)
    w = (N / (K * np.bincount(y)))[y] / N; lam = 1.0 / N; Y = np.eye(K)[y]
    W = np.zeros((K, D)); b = np.zeros(K); vW = np.zeros_like(W); vb = np.zeros_like(b)
    for _ in range(steps):
        Z = Xt @ W.T + b; Z -= Z.max(1, keepdims=True); Pr = np.exp(Z); Pr /= Pr.sum(1, keepdims=True)
        G = (Pr - Y) * w[:, None]
        vW = momentum * vW - rate * (G.T @ Xt + lam * W); vb = momentum * vb - rate * G.sum(0); W += vW; b += vb
    return classes, W, b

CUTS = [0.5, 0.6, 0.7, 0.8, 0.9]

def score(train_X, test_X, label):
    right = total = strangers = through = short_right = short_total = 0; known, unknown = [], []
    for m in sorted(set(meeting[usable])):
        held = []
        for k in ['you', 'far', 'echo', 'room']:
            for sp in sorted(set(speaker[(meeting == m) & (kind == k)])):
                g = (meeting == m) & (kind == k) & (speaker == sp)
                if g.sum() >= 3 and names.get((m, sp)): held.append((g, names[(m, sp)]))
        for drop in [None] + sorted({t for _, t in held}):
            train = usable & (meeting != m) & (person != (drop or '\0'))
            if len(set(person[train])) < 2: continue
            classes, W, b = gd(train_X[train], person[train])
            for g, truth in held:
                if (drop is None and truth not in classes) or (drop is not None and truth != drop): continue
                Z = test_X[g] @ W.T + b; Z -= Z.max(1, keepdims=True); lp = Z - np.log(np.exp(Z).sum(1, keepdims=True))
                if drop is None:
                    short = dur[g] < 4
                    short_right += (classes[lp.argmax(1)] == truth)[short].sum(); short_total += short.sum()
                lp = lp.mean(0); p = np.exp(lp - lp.max()); p /= p.sum()
                if drop is None: right += classes[p.argmax()] == truth; total += 1; known.append((classes[p.argmax()] == truth, p.max()))
                else: strangers += 1; through += p.max() >= 0.5; unknown.append(p.max())
    print(f"{label}: voices named right {right}/{total}, strangers reaching 0.5 {through}/{strangers}, single clips under 4 s right {short_right}/{short_total}", flush=True)
    for cut in CUTS:
        print(f"  cut {cut:.2f}: right names suggested {sum(1 for ok, p in known if ok and p >= cut)}, wrong names {sum(1 for ok, p in known if not ok and p >= cut)}, strangers {sum(1 for p in unknown if p >= cut)}", flush=True)

score(P, P, 'pad')
score(T, T, 'tile')
score(P, T, 'learned pad, asked tile')
