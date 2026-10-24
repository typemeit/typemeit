"""What the app would suggest: its Voices files and meeting.json names, through the same model and rules.

SUPPORT points at the data folder the app ran on.
"""
import json, glob, base64, os, numpy as np
SUPPORT = os.environ['SUPPORT']
meetings = {}
for f in glob.glob(f'{SUPPORT}/Meetings/2026-*/meeting.json'):
    m = json.load(open(f)); meetings[m['id']] = (os.path.basename(os.path.dirname(f)), m)
voices = {}
for f in glob.glob(f'{SUPPORT}/Voices/*.json'):
    v = json.load(open(f)); d = v['dimensions']
    voices[os.path.basename(f)[:-5]] = {sp: np.frombuffer(base64.b64decode(x), dtype=np.float32).reshape(-1, d) for sp, x in v['speakers'].items()}
def label(s):
    if s['isYou']: return 'You'
    return s['name'].strip() if s.get('nameSource') else None
Xs, ys = [], []
for mid, (name, m) in meetings.items():
    for s in m['speakers']:
        if label(s) and mid in voices and s['id'] in voices[mid]:
            Xs.append(voices[mid][s['id']]); ys += [label(s)] * len(voices[mid][s['id']])
X = np.concatenate(Xs).astype(np.float64); y = np.array(ys)
classes, yi = np.unique(np.char.lower(y.astype(str)), return_inverse=True)
N, D = X.shape; K = len(classes)
w = (1 / (K * np.bincount(yi)))[yi]; Y = np.eye(K)[yi]; W = np.zeros((K, D)); b = np.zeros(K); vW = np.zeros_like(W); vb = np.zeros_like(b)
for _ in range(300):
    Z = X @ W.T + b; Z -= Z.max(1, keepdims=True); P = np.exp(Z); P /= P.sum(1, keepdims=True); G = (P - Y) * w[:, None]
    vW = 0.9 * vW - 4 * (G.T @ X + W / N); vb = 0.9 * vb - 4 * G.sum(0); W += vW; b += vb
print(f"trained on {N} clips of {K} people: {', '.join(classes)}\n")
for mid, (name, m) in sorted(meetings.items(), key=lambda kv: kv[1][0]):
    if mid not in voices: continue
    taken = {label(s).lower() for s in m['speakers'] if label(s)}
    cands = []
    for s in m['speakers']:
        if s['isYou'] or s.get('nameSource') or s['id'] not in voices[mid] or len(voices[mid][s['id']]) < 3: continue
        V = voices[mid][s['id']].astype(np.float64); Z = V @ W.T + b; Z -= Z.max(1, keepdims=True); lp = (Z - np.log(np.exp(Z).sum(1, keepdims=True))).mean(0)
        p = np.exp(lp - lp.max()); p /= p.sum(); k = p.argmax()
        cands.append((s['id'], s['name'], classes[k], p[k]))
    if not cands: continue
    used = set(); lines = []
    for sid, sname, who, p in sorted(cands, key=lambda c: -c[3]):
        ok = p >= 0.5 and who not in taken and who not in used
        if ok: used.add(who)
        lines.append(f"    {sname:10s} best {who:22s} {p:.2f} {'-> SUGGEST' if ok else ''}")
    print(name); print("\n".join(lines))
