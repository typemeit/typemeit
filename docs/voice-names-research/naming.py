"""Naming voices from voices named before: leave one call out, then strangers.

For each call, every voice that has a name (from the call's tiles or typed by
the user) and was heard on some other call is named from the other calls
alone. Then each such voice's person is removed from training too, to see what
a stranger scores. Compares sklearn's logistic regression, the plain gradient
descent the app runs, and nearest centroid.
"""
import json, glob, os, numpy as np, warnings
from sklearn.linear_model import LogisticRegression
warnings.filterwarnings('ignore')
OUT = os.environ.get('OUT', 'out')
ROOT = os.path.expanduser('~/Library/Application Support/TypeMeIt/Meetings')
rows = json.load(open(f'{OUT}/rows.json')); X = np.load(f'{OUT}/vecs.npy'); X /= np.linalg.norm(X, axis=1, keepdims=True)

names, seen = {}, set()
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

class Sk:
    def __init__(self, Xt, yt): self.m = LogisticRegression(class_weight='balanced', max_iter=3000).fit(Xt, yt); self.classes = self.m.classes_
    def logp(self, Xs): return self.m.predict_log_proba(Xs)

class GD:
    """Softmax regression, class-balanced, L2 1/(C·N), full-batch gradient descent with momentum: what the app runs."""
    STEPS, RATE, MOMENTUM = 300, 4.0, 0.9
    def __init__(self, Xt, yt):
        self.classes, y = np.unique(yt, return_inverse=True)
        N, D = Xt.shape; K = len(self.classes)
        w = (N / (K * np.bincount(y)))[y] / N; lam = 1.0 / N
        Y = np.eye(K)[y]; W = np.zeros((K, D)); b = np.zeros(K); vW = np.zeros_like(W); vb = np.zeros_like(b)
        for _ in range(self.STEPS):
            Z = Xt @ W.T + b; Z -= Z.max(1, keepdims=True); P = np.exp(Z); P /= P.sum(1, keepdims=True)
            G = (P - Y) * w[:, None]
            gW = G.T @ Xt + lam * W; gb = G.sum(0)
            vW = self.MOMENTUM * vW - self.RATE * gW; vb = self.MOMENTUM * vb - self.RATE * gb
            W += vW; b += vb
        self.W, self.b = W, b
    def logp(self, Xs):
        Z = Xs @ self.W.T + self.b; Z -= Z.max(1, keepdims=True); return Z - np.log(np.exp(Z).sum(1, keepdims=True))

class Centroid:
    def __init__(self, Xt, yt):
        self.classes = np.unique(yt); C = np.stack([Xt[yt == c].mean(0) for c in self.classes]); self.C = C / np.linalg.norm(C, axis=1, keepdims=True)
    def logp(self, Xs):  # cosine as a score, softmax with a temperature so the "posterior" is comparable
        Z = 20 * Xs @ self.C.T; Z -= Z.max(1, keepdims=True); return Z - np.log(np.exp(Z).sum(1, keepdims=True))

def voices(m):
    for k in ['you', 'far', 'echo', 'room']:
        for sp in sorted(set(speaker[(meeting == m) & (kind == k)])):
            g = (meeting == m) & (kind == k) & (speaker == sp)
            if g.sum() >= 3: yield k, sp, g

calls = sorted(set(meeting[usable]))
for Model in [Sk, GD, Centroid]:
    res = []  # (condition, right, posterior, cosine, kind)
    for m in calls:
        held = [(k, sp, g, names.get((m, sp))) for k, sp, g in voices(m)]
        for drop in [None] + sorted({t for *_, t in held if t}):
            train = usable & (meeting != m) & (person != (drop or '\0'))
            if len(set(person[train])) < 2: continue
            model = Model(X[train], person[train])
            cents = {c: X[train & (person == c)].mean(0) for c in model.classes}
            for k, sp, g, truth in held:
                if not truth or (drop is None and truth not in model.classes) or (drop is not None and truth != drop): continue
                lp = model.logp(X[g]).mean(0); p = np.exp(lp - lp.max()); p /= p.sum()
                best = model.classes[p.argmax()]; v = X[g].mean(0); v /= np.linalg.norm(v); c = cents[best]
                res.append(('stranger' if drop else 'known', best == truth, float(p.max()), float(v @ c / np.linalg.norm(c)), k))
    known = [r for r in res if r[0] == 'known']; strangers = [r for r in res if r[0] == 'stranger']
    print(f"\n== {Model.__name__}: known voices named right {sum(r[1] for r in known)}/{len(known)} "
          f"(far {sum(r[1] for r in known if r[4]=='far')}/{sum(1 for r in known if r[4]=='far')}, echo {sum(r[1] for r in known if r[4]=='echo')}/{sum(1 for r in known if r[4]=='echo')}, "
          f"room {sum(r[1] for r in known if r[4]=='room')}/{sum(1 for r in known if r[4]=='room')}, you {sum(r[1] for r in known if r[4]=='you')}/{sum(1 for r in known if r[4]=='you')}); strangers {len(strangers)}")
    for label, sel in [('known right', [r for r in known if r[1]]), ('known wrong', [r for r in known if not r[1]]), ('stranger', strangers)]:
        if sel:
            P = np.array([r[2] for r in sel]); C = np.array([r[3] for r in sel])
            print(f"  {label:11s} n={len(sel):3d} posterior p10/50/90 {np.percentile(P, [10, 50, 90]).round(2)}  cosine p10/50/90 {np.percentile(C, [10, 50, 90]).round(2)}")
    wrong_total = len(strangers) + sum(1 for r in known if not r[1]); right_total = sum(r[1] for r in known)
    print("  cut (posterior, cosine) -> right suggested / wrong suggested")
    for pt in [0.5, 0.7, 0.8, 0.9]:
        line = []
        for ct in [0.0, 0.6, 0.65, 0.7, 0.75]:
            ok = sum(1 for r in known if r[1] and r[2] >= pt and r[3] >= ct)
            bad = sum(1 for r in known + strangers if not r[1] and r[2] >= pt and r[3] >= ct)
            line.append(f"c{ct:.2f}: {ok}/{right_total} {bad}/{wrong_total}")
        print(f"   p{pt:.1f}  " + " | ".join(line))
