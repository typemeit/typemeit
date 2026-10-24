#!/usr/bin/env python3
"""Custom-word boosting trial: shipped Ultra against FluidAudio CTC boosting, through the app's own Transcriber.

  Scripts/asr-app-path/vocab_trial.py run      # builds the clip sets, runs the arms, writes the outputs
  Scripts/asr-app-path/vocab_trial.py score    # prints the table

Arms (appasr flags): plain = none, A = --matcher (shipped: Ultra + CustomWordMatcher), B = --boost, C = --boost --matcher.
The user's custom words come from <reference dir>/custom-terms.json ([{"text", "aliases"}]) and never print: counts only.
Clips: the asr-eval dictations and meeting tracks (reference = AssemblyAI with the listen-review decisions), plus
synthesised `say` sentences with and without each term (reference = the sentence). Outputs go to <reference dir>/vocab-trial/."""
import json, pathlib, re, subprocess, sys

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[0] / 'asr-eval'))
import asr_eval, core, store  # noqa: E402

OUT = store.sub('vocab-trial')
ARMS = {'plain': [], 'A': ['--matcher'], 'B': ['--boost'], 'C': ['--boost', '--matcher']}
TEMPLATES = ['Can you send {} to the team before Friday', 'I was talking to someone about {} yesterday and it went well', 'Let me check with {} and then get back to you']
GENERIC = ['the budget report', 'the quarterly plan', 'the new schedule', 'the shared folder', 'the design review']
VOICES = ['Samantha', 'Daniel']
REPEAT = 3

def terms():
    return json.load(open(store.root() / 'custom-terms.json'))

def letters(text):
    return re.sub(r'[^a-z0-9]', '', text.lower())

def occurrences(text, term):
    """Non-overlapping runs of 1-3 words whose letters spell the term."""
    target, words, count, i = letters(term), [letters(w) for w in re.findall(r"[\w.'’-]+", text)], 0, 0
    while i < len(words):
        for n in (1, 2, 3):
            if i + n <= len(words) and ''.join(words[i:i + n]) == target:
                count += 1
                i += n - 1
                break
        i += 1
    return count

def synth_items():
    folder = store.sub('vocab-trial/synth')
    items, sentences = [], {}
    def make(clip_id, sentence, voice):
        wav = folder / f'{clip_id}.wav'
        if not wav.exists():
            aiff = folder / f'{clip_id}.aiff'
            subprocess.run(['say', '-v', voice, '-o', str(aiff), sentence], check=True)
            subprocess.run(['ffmpeg', '-v', 'error', '-y', '-i', str(aiff), '-ac', '1', '-ar', '16000', str(wav)], check=True)
            aiff.unlink()
        items.append({'id': clip_id, 'path': str(wav)})
        sentences[clip_id] = sentence
    for t, term in enumerate(terms()):
        for k, template in enumerate(TEMPLATES):
            for v, voice in enumerate(VOICES):
                make(f's-t{t}-{k}-{v}', template.format(term['text']), voice)
    for g, generic in enumerate(GENERIC):
        for k, template in enumerate(TEMPLATES):
            for v, voice in enumerate(VOICES):
                make(f's-g{g}-{k}-{v}', template.format(generic), voice)
    return items, sentences

def real_items(kind):
    prefix = 'd-' if kind == 'dictation' else 'm-'
    return [{'id': c['id'], 'path': str(store.sub('wav') / f"{c['id']}.wav")} for c in store.clips() if c['id'].startswith(prefix)]

def run():
    synth, sentences = synth_items()
    json.dump(sentences, open(OUT / 'synth-sentences.json', 'w'))
    sets = {'dictation': real_items('dictation') + synth, 'meeting': real_items('meeting')}
    for kind, items in sets.items():
        listing = OUT / f'{kind}-items.json'
        json.dump(items, open(listing, 'w'))
        for arm, flags in ARMS.items():
            target = OUT / f'{kind}-{arm}.json'
            if target.exists():
                continue
            extra = ['--terms', str(store.root() / 'custom-terms.json')] + flags + (['--repeat', str(REPEAT)] if kind == 'dictation' else [])
            subprocess.run([str(HERE / 'run.sh'), kind, str(listing), str(target)] + extra, check=True)

def pct(values, q):
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(q * len(ordered)))]

def references():
    decisions = asr_eval.decisions_by_clip()
    refs = {}
    for clip in store.clips():
        ref, _, spans = asr_eval.spans_for(clip)
        fixed, _, _ = asr_eval.corrected(clip, ref, spans, decisions.get(clip['id'], []))
        refs[clip['id']] = ' '.join(fixed)
    return refs

def score():
    refs, sentences = references(), json.load(open(OUT / 'synth-sentences.json'))
    names = [t['text'] for t in terms()]
    print(f'{len(names)} custom words, {sum(1 for t in terms() if t["aliases"])} with aliases')
    for kind in ('dictation', 'meeting'):
        runs = {arm: json.load(open(OUT / f'{kind}-{arm}.json')) for arm in ARMS}
        texts = {arm: {c['id']: c['text'] for c in r['clips']} for arm, r in runs.items()}
        real = [i['id'] for i in json.load(open(OUT / f'{kind}-items.json')) if not i['id'].startswith('s-')]
        carrying = [i for i in real if any(occurrences(refs[i], n) for n in names)]
        print(f'\n== {kind}: {len(real)} real clips, {len(carrying)} whose reference holds a custom word')
        for arm in ARMS:
            def wer(ids):
                errors = words = 0
                for i in ids:
                    ref = core.tokens(refs[i]); e, n = core.wer_counts(ref, core.tokens(texts[arm][i]))
                    errors += e; words += n
                return 100 * errors / max(1, words), errors, words
            total = wer(real); without = wer([i for i in real if i not in carrying]); with_ = wer(carrying)
            want = got = false = 0
            for i in real:
                for n in names:
                    r, h = occurrences(refs[i], n), occurrences(texts[arm][i], n)
                    want += r; got += min(r, h); false += max(0, h - r)
            line = f'{arm:5} WER {total[0]:5.2f}% ({total[1]}/{total[2]}); without custom words {without[0]:5.2f}% ({without[2]} words); with {with_[0]:5.2f}% ({with_[2]} words); real hits {got}/{want}; false insertions {false}'
            clips = [c for c in runs[arm]['clips'] if not c['id'].startswith('s-')]
            if kind == 'dictation':
                ms = [c['ms'] for c in clips]
                line += f'; p50 {pct(ms, .5):.0f} p95 {pct(ms, .95):.0f} ms; matcher p95 {pct([c["matcherMs"] for c in clips], .95):.2f} ms'
            else:
                line += f'; {sum(c["audioSeconds"] for c in clips) / (sum(c["ms"] for c in clips) / 1000):.0f}x realtime'
            line += f'; peak {runs[arm]["peakBytes"] / 1e6:.0f} MB; load {runs[arm]["loadSeconds"]:.1f} s'
            if runs[arm]['rescoreMs']:
                line += f'; rescore p50 {pct(runs[arm]["rescoreMs"], .5):.0f} p95 {pct(runs[arm]["rescoreMs"], .95):.0f} ms'
            print(line)
    print('\n== synthesised sentences')
    runs = {arm: {c['id']: c['text'] for c in json.load(open(OUT / f'dictation-{arm}.json'))['clips']} for arm in ARMS}
    for arm in ARMS:
        want = got = false = clean = clean_total = 0
        errors = words = 0
        for clip_id, sentence in sentences.items():
            hyp = runs[arm][clip_id]
            e, n = core.wer_counts(core.tokens(sentence), core.tokens(hyp)); errors += e; words += n
            for n_ in names:
                r, h = occurrences(sentence, n_), occurrences(hyp, n_)
                want += r; got += min(r, h); false += max(0, h - r)
        print(f'{arm:5} term hits {got}/{want} ({100 * got / want:.1f}%); false insertions {false}; WER {100 * errors / words:.2f}% ({errors}/{words})')

if __name__ == '__main__':
    {'run': run, 'score': score}[sys.argv[1]]()
