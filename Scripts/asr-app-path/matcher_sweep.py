#!/usr/bin/env python3
"""Custom-word matcher threshold sweep over words saved from the shipped speech model.

  appasr <dictation|meeting> ... --dump-words      saves each clip's words with confidences (vocab-trial/{dictation,meeting}-words.json)
  Scripts/asr-app-path/matcher_sweep.py hist       word confidence, correct vs wrong, on the real dictations
  Scripts/asr-app-path/matcher_sweep.py classify   why each false insertion fired, counts only
  Scripts/asr-app-path/matcher_sweep.py sweep      tune/held-out table per setting; settings go through the scratch matcher's TUNE_* variables
  Scripts/asr-app-path/matcher_sweep.py report     the shipped matcher, no overrides, tune and held-out

Clips split by the parity of a hash of the clip id: even = tune, odd = held-out, real and synthesised alike.
Custom words never print: counts only."""
import collections, difflib, hashlib, itertools, json, os, pathlib, subprocess, sys

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[0] / 'asr-eval'))
sys.path.insert(0, str(HERE))
import core, store  # noqa: E402
import vocab_trial as vt  # noqa: E402

OUT = vt.OUT
SCRATCH = HERE.parents[1] / 'build/asr-app-path'

def half(clip_id):
    return 'tune' if int(hashlib.sha1(clip_id.encode()).hexdigest(), 16) % 2 == 0 else 'held'

def words_of(kind):
    return {c['id']: c['words'] for c in json.load(open(OUT / f'{kind}-words.json'))['clips']}

def binary():
    return subprocess.run(['swift', 'build', '-c', 'release', '--package-path', str(SCRATCH), '--show-bin-path'], capture_output=True, text=True, check=True).stdout.strip() + '/appasr'

def rematch(kind, env):
    target = OUT / f'{kind}-rematch.json'
    subprocess.run([binary(), 'rematch', str(OUT / f'{kind}-words.json'), str(target), '--terms', str(store.root() / 'custom-terms.json')],
                   env={**os.environ, **{k: str(v) for k, v in env.items()}}, check=True)
    return {c['id']: c['text'] for c in json.load(open(target))['clips']}

def norm(word):
    return ''.join(core.tokens(word))

def aligned(ref_words, hyp_words):
    """For each hyp word: True when it matches a reference word in the alignment."""
    matcher = difflib.SequenceMatcher(None, ref_words, [norm(w['t']) for w in hyp_words], autojunk=False)
    right = [False] * len(hyp_words)
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag == 'equal':
            for j in range(j1, j2): right[j] = True
    return right

def hist():
    refs = vt.references()
    ids = [i['id'] for i in json.load(open(OUT / 'dictation-items.json')) if not i['id'].startswith('s-')]
    saved = words_of('dictation')
    edges = [0, .5, .6, .7, .75, .8, .85, .9, .95, 1.0001]
    counts = {True: collections.Counter(), False: collections.Counter()}
    for i in ids:
        ref = [''.join(core.tokens(w)) for w in refs[i].split()]
        ref = [w for w in ref if w]
        hyp = [w for w in saved[i] if norm(w['t'])]
        for ok, w in zip(aligned(ref, hyp), hyp):
            c = w['c'] if w['c'] is not None else 1
            counts[ok][next(k for k in range(len(edges) - 1) if edges[k] <= c < edges[k + 1])] += 1
    print('confidence bin   correct   wrong')
    for k in range(len(edges) - 1):
        print(f'{edges[k]:.2f}-{min(edges[k+1],1):.2f}      {counts[True][k]:7d} {counts[False][k]:7d}')
    for name, flag in (('correct', True), ('wrong', False)):
        total = sum(counts[flag].values())
        print(name, total, 'words;', sum(counts[flag][k] for k in range(len(edges) - 1) if edges[k] < .9), 'under 0.9;', sum(counts[flag][k] for k in range(len(edges) - 1) if edges[k] < .75), 'under 0.75')

def names():
    return [t['text'] for t in vt.terms()]

def counts_for(texts, ids, refs):
    want = got = false = 0
    for i in ids:
        for n in names():
            r, h = vt.occurrences(refs[i], n), vt.occurrences(texts[i], n)
            want += r; got += min(r, h); false += max(0, h - r)
    return want, got, false

def wer(texts, ids, refs):
    errors = total = 0
    for i in ids:
        e, n = core.wer_counts(core.tokens(refs[i]), core.tokens(texts[i])); errors += e; total += n
    return 100 * errors / max(1, total), errors, total

def evaluate(env, plain=None):
    refs, sentences = vt.references(), json.load(open(OUT / 'synth-sentences.json'))
    out = {}
    dictation = rematch('dictation', env)
    meeting = rematch('meeting', env)
    real = [i['id'] for i in json.load(open(OUT / 'dictation-items.json')) if not i['id'].startswith('s-')]
    meet = [i['id'] for i in json.load(open(OUT / 'meeting-items.json'))]
    for part in ('tune', 'held', 'all'):
        pick = lambda ids: [i for i in ids if part == 'all' or half(i) == part]
        carrying = [i for i in pick(real) if any(vt.occurrences(refs[i], n) for n in names())]
        rw, rg, rf = counts_for(dictation, pick(real), refs)
        sw, sg, sf = counts_for(dictation, pick(list(sentences)), refs | sentences)
        _, mg, mf = counts_for(meeting, pick(meet), refs)
        out[part] = dict(wer=wer(dictation, pick(real), refs), wer_without=wer(dictation, [i for i in pick(real) if i not in carrying], refs),
                         real_hits=(rg, rw), real_false=rf, synth_hits=(sg, sw), synth_false=sf, meeting_false=mf,
                         synth_wer=wer(dictation, pick(list(sentences)), refs | sentences))
    return out, dictation

def fired(kind, env):
    """Every run the matcher replaced by a term: (clip, how it matched, lowest confidence, words in the run, correct per the reference)."""
    refs = vt.references() | json.load(open(OUT / 'synth-sentences.json'))
    saved, after = words_of(kind), rematch(kind, env)
    terms = vt.terms()
    rows = []
    for clip_id, words in saved.items():
        if kind == 'dictation' and clip_id.startswith('s-') is False and clip_id not in refs: continue
        out = after[clip_id].split()
        matcher = difflib.SequenceMatcher(None, [w['t'] for w in words], out, autojunk=False)
        for tag, i1, i2, j1, j2 in matcher.get_opcodes():
            if tag == 'equal': continue
            produced = ''.join(vt.letters(w) for w in out[j1:j2])
            term = next((t for t in terms if vt.letters(t['text']) == produced), None)
            if term is None or i1 == i2: continue
            heard = ''.join(vt.letters(w['t']) for w in words[i1:i2])
            how = 'exact spelling' if heard == produced else 'alias' if heard in [vt.letters(a) for a in term['aliases']] else 'sound match'
            confidences = [w['c'] for w in words[i1:i2] if w['c'] is not None]
            correct = vt.occurrences(refs[clip_id], term['text']) > 0
            rows.append((clip_id, how, min(confidences) if confidences else None, i2 - i1, correct))
    return rows

def classify():
    for kind in ('dictation', 'meeting'):
        rows = fired(kind, {})
        wrong = [r for r in rows if not r[4]]
        print(f'== {kind}: {len(rows)} replacements, {len(wrong)} in clips whose reference lacks that word')
        for group, label in ((wrong, 'false'),):
            by = collections.Counter()
            for clip, how, conf, n, _ in group:
                band = 'no confidence' if conf is None else 'under 0.75 (relaxed bar)' if conf < .75 else '0.75 to 0.9'
                part = 'synth' if clip.startswith('s-') else 'real'
                by[(part, how, band, f'{n} word' + ('s' if n > 1 else ''))] += 1
            for key, n in sorted(by.items()):
                print(' ', n, *key)

def plain_texts():
    return {c['id']: ' '.join(w['t'] for w in c['words']) for c in json.load(open(OUT / 'dictation-words.json'))['clips']}

def line(label, result):
    cells = []
    for part in ('tune', 'held', 'all'):
        r = result[part]
        cells.append(f"{part}: WER {r['wer'][0]:.2f} (w/o {r['wer_without'][0]:.2f}) real {r['real_hits'][0]}/{r['real_hits'][1]} f{r['real_false']} synth {r['synth_hits'][0]}/{r['synth_hits'][1]} f{r['synth_false']} meet f{r['meeting_false']}")
    print(f'{label:34}', ' | '.join(cells), flush=True)

def sweep():
    plain = {k: v for k, v in plain_texts().items()}
    refs = vt.references() | json.load(open(OUT / 'synth-sentences.json'))
    real = [i for i in plain if not i.startswith('s-')]
    print('plain (no matcher): WER all', f'{wer(plain, real, refs)[0]:.2f}', 'tune', f"{wer(plain, [i for i in real if half(i)=='tune'], refs)[0]:.2f}", 'held', f"{wer(plain, [i for i in real if half(i)=='held'], refs)[0]:.2f}")
    grid = [{'TUNE_V': 2, 'TUNE_RUN': r} for r in (0, 0.05, 0.1, 0.15, 0.2)]
    for env in grid:
        result, _ = evaluate(env)
        line(' '.join(f'{k[5:9].lower()}={v}' for k, v in env.items()) or 'dict only', result)

def report():
    result, _ = evaluate({})
    line('current', result)

if __name__ == '__main__':
    {'hist': hist, 'classify': classify, 'sweep': sweep, 'report': report}[sys.argv[1]]()
