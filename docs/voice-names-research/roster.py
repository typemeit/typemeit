"""Does the call's roster help? Candidates narrowed to the roster (plus You) when there is one."""
exec(open('naming.py').read().split("calls = sorted")[0])
rosters = {}
seen2 = set()
for f in sorted(glob.glob(f'{ROOT}/2026-*')):
    g = os.path.basename(f)[:15]
    if g in seen2 or not os.path.exists(f'{f}/meeting.json'): continue
    m = json.load(open(f'{f}/meeting.json'))
    if m['kind'] != 'call' or not m.get('tracks'): continue
    seen2.add(g); rosters[g] = (m.get('names') or {}).get('roster') or []
calls = sorted(set(meeting[usable]))
res = []
for m in calls:
    roster = set(rosters.get(m, []))
    if not roster: continue
    held = [(k, sp, g, names.get((m, sp))) for k, sp, g in voices(m)]
    taken = {t for *_, t in held if t}
    for drop in [None] + sorted(taken):
        train = usable & (meeting != m) & (person != (drop or '\0'))
        model = GD(X[train], person[train])
        for k, sp, g, truth in held:
            if not truth or (drop is None and truth not in model.classes) or (drop is not None and truth != drop): continue
            # candidates: roster names the model knows, plus You; names other voices in this call hold are not excluded here (worst case)
            allowed = np.array([c in roster or c == 'You' for c in model.classes])
            if allowed.sum() < 1: continue
            lp = model.logp(X[g]).mean(0); lp = np.where(allowed, lp, -np.inf); p = np.exp(lp - lp.max()); p /= p.sum()
            best = model.classes[p.argmax()]
            res.append(('stranger' if drop else 'known', best == truth, float(p.max()), k, int(allowed.sum())))
known = [r for r in res if r[0] == 'known']; strangers = [r for r in res if r[0] == 'stranger']
print(f"calls with a roster: known voices {len(known)} (right {sum(r[1] for r in known)}), strangers {len(strangers)} (candidates median {np.median([r[4] for r in strangers]) if strangers else 0})")
for pt in [0.5, 0.7, 0.8, 0.9, 0.95]:
    ok = sum(1 for r in known if r[1] and r[2] >= pt); bad = sum(1 for r in known + strangers if not r[1] and r[2] >= pt)
    print(f"  p>={pt}: right {ok}/{sum(r[1] for r in known)}, wrong {bad}/{len(strangers) + sum(1 for r in known if not r[1])}")
P = np.array([r[2] for r in strangers]); print("  stranger posterior p50/p90/max", np.percentile(P, [50, 90, 100]).round(2))
