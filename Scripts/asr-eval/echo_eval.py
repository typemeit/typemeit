"""Echo on kept call meetings: how many mic-track words are the far end heard again through the
mic, before and after the app's EchoFold, and after LocalVQE. Reads the AssemblyAI cache only.

usage: python3 echo_eval.py [--vqe]   (--vqe scores the Parakeet text of the LocalVQE-cleaned mic;
the cleaned mic's Parakeet text is read from ASR_EVAL_VQE_TEXT, a json {"m-<id>-mic-vqe": text})"""
import difflib, json, os, subprocess, sys, pathlib
import store, core, assemblyai

CALLS = ['df6fab7f', 'f1041686', '11b92bbd']
TOLERANCE_MS = 400      # same as EchoFold.toleranceMs
RETURNED_MS = 100       # others copy later than the mic's by more than this is the user's voice returning
MIN_RUN = 2

def clip(cid):
    return next(c for c in store.clips() if c['id'] == cid)

def aai_words(cid, speakers):
    c = clip(cid)
    result = store.read_json(assemblyai.cache_path(store.clip_audio(c), speakers))
    return [dict(w, text=' '.join(core.tokens(w['text'])) ) for w in assemblyai.words(result) if core.tokens(w['text'])]

def echo_flags(mic, others):
    """mic, others: [{text, startMs}]. A mic word is echo when it sits in a run of at least MIN_RUN
    consecutive mic words each matching a same-text far-end word whose start is within
    TOLERANCE_MS and not more than RETURNED_MS after the mic's own (the far end ahead of the mic)."""
    starts = {}
    for w in others:
        starts.setdefault(w['text'], []).append(w['startMs'])
    match = []
    for w in mic:
        match.append(any(-RETURNED_MS <= w['startMs'] - s <= TOLERANCE_MS for s in starts.get(w['text'], [])))
    flags = [False] * len(mic)
    i = 0
    while i < len(mic):
        if match[i]:
            j = i
            while j < len(mic) and match[j]:
                j += 1
            if j - i >= MIN_RUN:
                for k in range(i, j):
                    flags[k] = True
            i = j
        else:
            i += 1
    return flags

def rate(flags):
    return sum(flags), len(flags)

def inherit_times(mic_aai, tokens):
    """Times for another transcript's tokens: matched words take the AssemblyAI mic word's start,
    the rest the previous matched start."""
    ref = [w['text'] for w in mic_aai]
    times = [None] * len(tokens)
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, ref, tokens, autojunk=False).get_opcodes():
        if tag == 'equal':
            for k in range(i2 - i1):
                times[j1 + k] = mic_aai[i1 + k]['startMs']
    last = 0
    for k, t in enumerate(times):
        if t is None:
            times[k] = last
        else:
            last = t
    return times

def main():
    vqe_text = store.read_json(os.environ.get('ASR_EVAL_VQE_TEXT', str(store.root() / 'vqe' / 'parakeet.json')), {})
    rows = []
    for cid in CALLS:
        mic, others = aai_words(f'm-{cid}-mic', False), aai_words(f'm-{cid}-others', True)
        flags = echo_flags(mic, others)
        wavs = store.sub('wav')
        words = {'mic': [{'text': w['text'], 'startMs': w['startMs'], 'endMs': w['endMs']} for w in mic],
                 'others': [{'text': w['text'], 'startMs': w['startMs'], 'endMs': w['endMs']} for w in others]}
        tmp = store.root() / 'vqe' / f'{cid}-words.json'
        tmp.write_text(json.dumps(words))
        fold = json.loads(subprocess.run([str(pathlib.Path(__file__).parent / 'echofold/run.sh'), str(tmp), str(wavs / f'm-{cid}-mic.wav'), str(wavs / f'm-{cid}-others.wav')],
                                         capture_output=True, text=True, check=True).stdout.splitlines()[-1])
        kept = set(fold['keptMic'])
        after_fold = [f for i, f in enumerate(flags) if i in kept]
        row = {'call': cid, 'micWords': len(mic), 'othersWords': len(others), 'verdict': fold['verdict'], 'lagShowsEcho': fold['showsEcho'],
               'rawEcho': rate(flags), 'foldDropped': fold['droppedFromMic'], 'foldEchoLeft': rate(after_fold),
               'foldDroppedNonEcho': sum(1 for i, f in enumerate(flags) if i not in kept and not f)}
        # Parakeet raw and cleaned, against AssemblyAI's mic reading
        ref_tokens = [w['text'] for w in mic]
        for label, text in (('parakeetRaw', store.read_json(store.sub('systems/parakeet') / f'm-{cid}-mic.json')['text']), ('parakeetVqe', vqe_text.get(f'm-{cid}-mic-vqe'))):
            if text is None:
                continue
            toks = core.tokens(text)
            hyp = [{'text': t, 'startMs': s} for t, s in zip(toks, inherit_times(mic, toks))]
            hf = echo_flags(hyp, others)
            errors, n = core.wer_counts(ref_tokens, toks)
            # recall of the reference words that are not echo: reference words kept in the alignment
            matcher = difflib.SequenceMatcher(None, ref_tokens, toks, autojunk=False)
            matched = [False] * len(ref_tokens)
            for tag, i1, i2, j1, j2 in matcher.get_opcodes():
                if tag == 'equal':
                    for k in range(i1, i2):
                        matched[k] = True
            nonecho = [i for i, f in enumerate(flags) if not f]
            row[label] = {'words': len(toks), 'wer': errors / n, 'echo': rate(hf),
                          'nearEndRecall': sum(matched[i] for i in nonecho) / max(len(nonecho), 1),
                          'echoRefRecall': sum(matched[i] for i, f in enumerate(flags) if f) / max(sum(flags), 1),
                          'foldKeptRecall': sum(matched[i] for i in kept) / max(len(kept), 1)}
        rows.append(row)
    print(json.dumps(rows, indent=1))

main()
