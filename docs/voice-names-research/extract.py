"""Labelled clips from every recorded call, plus dictations, embedded with the app's WeSpeaker model.

kind:
  you       mic track, a 'you' paragraph the far end hardly overlaps
  far       far-end track, any far-end speaker (call-audio channel)
  echo      mic track during far-end speech with no mic paragraph near it: the laptop
            speakers heard by the mic
  room      mic track, a room voice r1/r2/... split off by RoomVoices
  dictation a kept dictation
Writes $OUT/rows.json and $OUT/vecs.npy (OUT defaults to ./out).
"""
import json, os, glob, numpy as np, emb
ROOT = os.path.expanduser('~/Library/Application Support/TypeMeIt')
OUT = os.environ.get('OUT', 'out'); os.makedirs(OUT, exist_ok=True)
MIN_S, MAX_S, PAD_MS = 1.5, 10.0, 500
rows, vecs = [], []

def add(clip, **meta):
    if len(clip) < MIN_S * emb.RATE: return
    vecs.append(emb.embedding(clip)); rows.append(meta | {'dur': round(len(clip) / emb.RATE, 2), 'rms_db': round(float(20 * np.log10(np.sqrt(np.mean(clip ** 2)) + 1e-9)), 1)})

def windows(start_ms, end_ms):
    """Spans of at most MAX_S; a short tail merges into the window before it."""
    out, s = [], start_ms
    while end_ms - s >= MIN_S * 1000:
        e = s + MAX_S * 1000
        if end_ms - e < MIN_S * 1000: e = end_ms
        out.append((s, min(e, end_ms))); s = e
    return out

def overlap(a0, a1, spans):
    return sum(max(0, min(a1, b1) - max(a0, b0)) for b0, b1 in spans)

seen = set()
for folder in sorted(glob.glob(f'{ROOT}/Meetings/2026-*')):
    meeting = json.load(open(f'{folder}/meeting.json'))
    group = os.path.basename(folder)[:15]
    if meeting['kind'] != 'call' or not meeting.get('tracks') or group in seen: continue
    seen.add(group)
    tracks = {t['role']: emb.decode(f"{folder}/{t['file']}") for t in meeting['tracks']}
    paras = meeting['paragraphs']
    is_mic = lambda p: p['speaker'] == 'you' or p['speaker'].startswith('r')
    far = [(p['startMs'], p['endMs']) for p in paras if not is_mic(p)]
    mic = [(p['startMs'], p['endMs']) for p in paras if is_mic(p)]
    cut = lambda role, s, e: tracks[role][int(s * 16):int(e * 16)]
    for p in paras:
        for s, e in windows(p['startMs'], p['endMs']):
            if p['speaker'] == 'you':
                if overlap(s, e, far) > 0.1 * (e - s): continue
                add(cut('mic', s, e), kind='you', meeting=group, speaker='you', start=s)
            elif p['speaker'].startswith('r'):
                if overlap(s, e, far) > 0.1 * (e - s): continue
                add(cut('mic', s, e), kind='room', meeting=group, speaker=p['speaker'], start=s)
            else:
                add(cut('others', s, e), kind='far', meeting=group, speaker=p['speaker'], start=s)
                if overlap(s - PAD_MS, e + PAD_MS, mic) == 0:
                    add(cut('mic', s, e), kind='echo', meeting=group, speaker=p['speaker'], start=s)
    print(group, {k: sum(1 for r in rows if r['meeting'] == group and r['kind'] == k) for k in ['you', 'far', 'echo', 'room']}, flush=True)

for path in sorted(glob.glob(f'{ROOT}/Recordings/*.m4a'), key=os.path.getmtime):
    try: audio = emb.decode(path)
    except Exception: print('unreadable', os.path.basename(path)); continue
    add(audio[:int(MAX_S * emb.RATE)], kind='dictation', meeting='dictation', speaker='you', start=0, file=os.path.basename(path))
print('dictations', sum(1 for r in rows if r['kind'] == 'dictation'))
np.save(f'{OUT}/vecs.npy', np.stack(vecs)); json.dump(rows, open(f'{OUT}/rows.json', 'w'))
