"""The app's gradient descent against scikit-learn, and the export the Swift check reads.

Trains on every call but 6 Oct 14:34 and scores that call's voices plus a few
held-out voices from 2 Oct; writes $OUT/parity.bin for parity.swift.
"""
exec(open('naming.py').read().split("calls = sorted")[0])
import struct
held_call = '2026-10-02 0959'
train = usable & (meeting != held_call)
sk = Sk(X[train], person[train]); gd = GD(X[train], person[train])
long = GD.__new__(GD); GD.STEPS = 1000; long.__init__(X[train], person[train]); GD.STEPS = 300
assert list(sk.classes) == list(gd.classes)
diffs, diffs_long = [], []
groups = [(k, sp, g) for k, sp, g in voices(held_call)]
for k, sp, g in groups:
    def post(m): lp = m.logp(X[g]).mean(0); p = np.exp(lp - lp.max()); return p / p.sum()
    a, b, c = post(sk), post(gd), post(long)
    diffs.append(np.abs(a - b).max()); diffs_long.append(np.abs(c - b).max())
    print(f"{k}:{sp:4s} sklearn {sk.classes[a.argmax()]:16s} {a.max():.3f} | app {gd.classes[b.argmax()]:16s} {b.max():.3f} | 1000 steps {c.max():.3f}")
print(f"largest posterior gap: sklearn vs app {max(diffs):.3f}, 300 vs 1000 steps {max(diffs_long):.3f}")
# export for Swift: training rows, labels, held groups
names_list = list(gd.classes); lab = np.array([names_list.index(p) for p in person[train]], dtype=np.int32)
with open(f'{OUT}/parity.bin', 'wb') as f:
    Xt = X[train].astype(np.float32); f.write(struct.pack('<iii', Xt.shape[0], Xt.shape[1], len(names_list)))
    f.write(Xt.tobytes()); f.write(lab.tobytes())
    f.write(struct.pack('<i', len(groups)))
    for k, sp, g in groups:
        V = X[g].astype(np.float32); lp = gd.logp(X[g]).mean(0); p = np.exp(lp - lp.max()); p /= p.sum()
        f.write(struct.pack('<i', V.shape[0])); f.write(V.tobytes()); f.write(p.astype(np.float32).tobytes())
json.dump(names_list, open(f'{OUT}/parity-names.json', 'w'))
