#!/usr/bin/env python3
"""ASR and diarization eval against an AssemblyAI reference with hand-checked disagreements.
See README.md. usage: asr_eval.py build|run|disagree|review|score ..."""
import argparse, collections, hashlib, importlib, json, os, pathlib, random, subprocess, sys, tempfile, time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import assemblyai, core, review_server, store, vault

DICTATION_LIMIT = 50
PAD_S = 0.6
CONTEXT_WORDS = 8
CONTEXT_S = 1.0
# A pick set asks which words were said, which needs more of the sentence around them.
PICK_CONTEXT_S = 2.0
MAX_PLAY_S = 10.0
# A who set plays a sample of each voice: the nearest stretch of it everyone agrees on, at
# least WHO_SAMPLE_MIN_MS long and cut to WHO_SAMPLE_MAX_MS; words closer than WHO_JOIN_MS
# are one stretch. "A few seconds either side" is WHO_CONTEXT_S.
WHO_SAMPLE_MIN_MS = 4000
WHO_SAMPLE_MAX_MS = 5000
WHO_JOIN_MS = 600
WHO_CONTEXT_S = 2.5
SET_SIZE = 40
SET_SEED = 7
WIDE_GAP_MS = 2000
SET_SYSTEM = 'fluid-ultra'
SET_OTHER = 'parakeet'
SET_NAME = 'ultra-insertions'

def short(text):
    return hashlib.sha1(text.encode()).hexdigest()[:8]

# ---- build ----

def find_clips(dictations):
    found = []
    meetings = store.data_dir() / 'Meetings'
    for folder in sorted(meetings.glob('*/meeting.json')):
        meta = store.read_json(folder)
        for track in (meta or {}).get('tracks', []):
            audio = folder.parent / track['file']
            if audio.exists():
                found.append({'id': f"m-{short(folder.parent.name)}-{track['role']}", 'kind': 'meeting',
                              'speakers': track['role'] in ('others', 'room'), 'source': str(audio)})
    recordings = sorted((store.data_dir() / 'Recordings').glob('*.m4a'), key=lambda p: p.stat().st_mtime, reverse=True)
    for audio in recordings[:dictations]:
        found.append({'id': f'd-{audio.stem[:8].lower()}', 'kind': 'dictation', 'speakers': False, 'source': str(audio)})
    return found

def build(args):
    audio_dir = store.sub('audio')
    # --keep fetches references for the clips already chosen (a new reference model), so scores
    # stay comparable and no newer recording is uploaded.
    selected = store.clips() if args.keep else find_clips(args.dictations)
    if args.limit:
        selected = selected[:args.limit]
    for clip in selected:
        source = pathlib.Path(clip['source'])
        clip['file'] = clip['id'] + source.suffix
        link = audio_dir / clip['file']
        if not link.exists():
            link.symlink_to(source)
    store.write_json(store.root() / 'clips.json', selected)
    for n, clip in enumerate(selected, 1):
        result = assemblyai.transcribe(store.clip_audio(clip), clip['speakers'])
        print(f"{n}/{len(selected)} {clip['id']} {core.counted(len(result.get('words') or []), 'word')}")

# ---- run ----

def load_adapter(kind, name):
    return importlib.import_module(f'{kind}.{name}')

def run(args):
    clips = store.clips()
    if args.like:
        clips = [c for c in clips if (store.sub(f'systems/{args.like}') / f"{c['id']}.json").exists()]
    module = args.system.replace('-', '_')
    if (pathlib.Path(__file__).parent / 'systems' / f'{module}.py').exists():
        adapter, folder = load_adapter('systems', module), 'systems'
        pending = [c for c in clips if not (store.sub(f'{folder}/{args.system}') / f"{c['id']}.json").exists() or args.force]
        outputs = adapter.transcribe([{'id': c['id'], 'path': store.clip_audio(c)} for c in pending]) if pending else {}
        for clip_id, text in outputs.items():
            store.write_json(store.sub(f'{folder}/{args.system}') / f'{clip_id}.json', {'text': text})
    elif (pathlib.Path(__file__).parent / 'diarizers' / f'{args.system}.py').exists():
        adapter, folder = load_adapter('diarizers', args.system), 'diarizers'
        for clip in (c for c in clips if c['speakers']):
            target = store.sub(f'{folder}/{args.system}') / f"{clip['id']}.json"
            if args.force or not target.exists():
                store.write_json(target, {'segments': adapter.diarize(store.clip_audio(clip))})
    else:
        raise SystemExit(f'no adapter named {args.system} in systems/ or diarizers/')
    print(f'{args.system}: done')

# ---- disagree ----

def reference(clip):
    return assemblyai.words(assemblyai.transcribe(store.clip_audio(clip), clip['speakers']))

def system_texts(clip):
    texts = {}
    for folder in sorted(store.sub('systems').iterdir()):
        data = store.read_json(folder / f"{clip['id']}.json")
        if data:
            texts[folder.name] = core.tokens(data['text'])
    return texts

def spans_for(clip):
    words = reference(clip)
    ref = core.tokens(' '.join(w['text'] for w in words))
    timed = [w for w in words for _ in core.tokens(w['text'])]
    return ref, timed, core.disagreements(ref, system_texts(clip))

def span_window(timed, start, end):
    """Start and end ms of ref[start:end] in the audio; an empty span sits at the next word's start."""
    if not timed:
        return 0, 0
    begin = timed[start]['startMs'] if start < len(timed) else timed[-1]['endMs']
    return begin, timed[end - 1]['endMs'] if end > start else begin

def disagree(args):
    out = []
    for clip in store.clips():
        ref, timed, spans = spans_for(clip)
        for span in spans:
            start, end = span['start'], span['end']
            begin, finish = span_window(timed, start, end)
            groups = {}
            for name, words in span['readings'].items():
                groups.setdefault(' '.join(words), []).append('assemblyai' if name == 'ref' else name)
            out.append({'key': core.span_key(clip['id'], ref, start, end), 'clip': clip['id'], 'start': start, 'end': end,
                        'startMs': begin, 'endMs': finish,
                        'before': ' '.join(ref[max(0, start - CONTEXT_WORDS):start]),
                        'after': ' '.join(ref[end:end + CONTEXT_WORDS]),
                        'readings': [{'text': text, 'systems': names} for text, names in groups.items()]})
    path = store.root() / 'review.jsonl'
    path.write_text(''.join(json.dumps(o) + '\n' for o in out))
    decided = {d['key'] for d in store.read_jsonl(store.root() / 'decisions.jsonl')}
    print(f"{core.counted(len(out), 'span')} to check, {len(decided & {o['key'] for o in out})} already decided")

# ---- judge ----
# Whether a disputed span changes the meaning is a text question, so a language model answers it
# (Claude Code agents read the exported spans and write one line per span); the ear is kept for
# whether words were said. Judgements are cached by core.judge_key and never asked twice.

def judgements_path():
    return store.root() / 'judgements.jsonl'

def judged():
    return {j['judgeKey']: j for j in store.read_jsonl(judgements_path())}

def span_context(ref, start, end):
    return ' '.join(ref[max(0, start - CONTEXT_WORDS):start]), ' '.join(ref[end:end + CONTEXT_WORDS])

def judge_export(args):
    known = judged()
    unjudged = {}
    for span in store.read_jsonl(store.root() / 'review.jsonl'):
        texts = [reading['text'] for reading in span['readings']]
        key = core.judge_key(span['before'], texts, span['after'])
        if key not in known:
            unjudged[key] = {'judgeKey': key, 'before': span['before'], 'after': span['after'], 'readings': span['readings']}
    pathlib.Path(args.out).write_text(''.join(json.dumps(span) + '\n' for span in unjudged.values()))
    print(f"{core.counted(len(unjudged), 'span')} to judge written to {args.out}; {len(known):,} already judged")

def judge_import(args):
    accepted = []
    for line in pathlib.Path(args.file).read_text().splitlines():
        verdict = json.loads(line)
        if verdict.get('kind') not in core.JUDGE_KINDS or not isinstance(verdict.get('matters'), bool):
            raise SystemExit(f'bad judgement: {line[:200]}')
        accepted.append({'judgeKey': verdict['judgeKey'], 'matters': verdict['matters'], 'kind': verdict['kind'],
                         'note': verdict.get('note', ''), 'by': args.by, 'at': int(time.time())})
    with open(judgements_path(), 'a') as f:
        f.writelines(json.dumps(j) + '\n' for j in accepted)
    print(f"{core.counted(len(accepted), 'judgement')} added")

# ---- review ----

def play_cut(clip_file, begin_s, length_s):
    with tempfile.TemporaryDirectory() as tmp:
        cut = os.path.join(tmp, 'cut.wav')
        subprocess.run(['ffmpeg', '-v', 'error', '-y', '-ss', f'{max(0, begin_s):.2f}', '-t', f'{length_s:.2f}',
                        '-i', clip_file, cut], check=True)
        subprocess.run(['afplay', cut])

def play(clip_file, start_ms, end_ms):
    play_cut(clip_file, start_ms / 1000 - PAD_S, (end_ms - start_ms) / 1000 + 2 * PAD_S)

def reads_differently(span, first, second):
    """True when the two systems gave this span different readings (a system that gave none counts as reading the reference)."""
    reading_of = {name: reading['text'] for reading in span['readings'] for name in reading['systems']}
    return reading_of.get(first) != reading_of.get(second)

def review(args):
    if args.set:
        return review_set(args)
    spans = store.read_jsonl(store.root() / 'review.jsonl')
    path = store.root() / 'decisions.jsonl'
    decided = {d['key'] for d in store.read_jsonl(path)}
    clips = {c['id']: c for c in store.clips()}
    todo = [s for s in spans if s['key'] not in decided]
    if args.between:
        todo = [s for s in todo if reads_differently(s, *args.between)]
        todo.sort(key=lambda s: not s['clip'].startswith('d-'))
    for n, span in enumerate(todo, 1):
        file = store.clip_audio(clips[span['clip']])
        while True:
            print(f"\n[{n}/{len(todo)}] {span['clip']}  {span['startMs'] / 1000:.1f}s")
            print(f"   ...{span['before']} [ ] {span['after']}...")
            for i, reading in enumerate(span['readings'], 1):
                print(f"   {i}. {reading['text'] or '(nothing)'}   <- {', '.join(reading['systems'])}")
            choice = input('   number / t=type / r=replay / s=skip / q=quit > ').strip().lower()
            if choice == 'r' or choice == '':
                play(file, span['startMs'], span['endMs'])
                continue
            if choice == 'q':
                return
            if choice == 's':
                break
            if choice == 't':
                text = input('   right words > ')
            elif choice.isdigit() and 1 <= int(choice) <= len(span['readings']):
                text = span['readings'][int(choice) - 1]['text']
            else:
                continue
            with open(path, 'a') as f:
                f.write(json.dumps({'key': span['key'], 'clip': span['clip'], 'start': span['start'], 'end': span['end'], 'text': text}) + '\n')
            break

# ---- focused review set: words fluid-ultra adds that neither AssemblyAI nor Parakeet has ----

def set_path(name=SET_NAME):
    return store.root() / f'{name}.json'

def answers_path(name=SET_NAME):
    return store.root() / f'{name}-answers.jsonl'

def latest_answers(name=SET_NAME):
    return {a['key']: a for a in store.read_jsonl(answers_path(name))}

def insertion_candidates(clip):
    """Runs of SET_SYSTEM words absent from both the reference and SET_OTHER, fillers ignored,
    each with the reference gap it sits in."""
    ref, timed, _ = spans_for(clip)
    texts = system_texts(clip)
    if SET_SYSTEM not in texts or SET_OTHER not in texts:
        return []
    kept = [i for i, w in enumerate(ref) if w not in core.FILLERS]
    ref_kept = [ref[i] for i in kept]
    runs = core.lone_insertions(ref_kept, core.drop_fillers(texts[SET_SYSTEM]), core.drop_fillers(texts[SET_OTHER]))
    found = []
    for run in runs:
        boundary = run['refIndex']
        full = kept[boundary] if boundary < len(kept) else len(ref)
        before = timed[kept[boundary - 1]]['endMs'] if boundary > 0 and timed else 0
        after = timed[full]['startMs'] if full < len(timed) else before
        found.append({'key': core.span_key(clip['id'], ref, full, full) + f"-{run['hypStart']}", 'clip': clip['id'],
                      'refIndex': full, 'words': run['words'], 'gapStartMs': before, 'gapEndMs': max(before, after),
                      'before': ' '.join(ref[max(0, full - CONTEXT_WORDS):full]), 'after': ' '.join(ref[full:full + CONTEXT_WORDS])})
    return found

def draw_set(candidates, size, seed=SET_SEED):
    """Spread over clips; within a clip, wide reference gaps that fit in one playback, with 2+ words, first."""
    def tier(c):
        gap = c['gapEndMs'] - c['gapStartMs']
        playable = gap <= (MAX_PLAY_S - 2 * CONTEXT_S) * 1000
        wide = gap > WIDE_GAP_MS
        if not playable:
            return 4
        return (0 if wide else 2) + (0 if len(c['words']) >= 2 else 1)
    rng = random.Random(seed)
    per_clip = {}
    for c in candidates:
        per_clip.setdefault(c['clip'], []).append(c)
    for items in per_clip.values():
        rng.shuffle(items)
        items.sort(key=tier)
    chosen = []
    while len(chosen) < size and any(per_clip.values()):
        for clip_id in sorted(per_clip):
            if per_clip[clip_id] and len(chosen) < size:
                chosen.append(per_clip[clip_id].pop(0))
    return chosen

def load_set(args):
    existing = store.read_json(set_path(args.set))
    if existing and not args.rebuild:
        return existing
    if args.set != SET_NAME:
        raise SystemExit(f'no set file {set_path(args.set)}: build it first')
    candidates = []
    for clip in store.clips():
        if clip['kind'] == 'meeting':
            candidates += insertion_candidates(clip)
    population = collections.defaultdict(lambda: {'spans': 0, 'words': 0})
    for c in candidates:
        population[c['clip']]['spans'] += 1
        population[c['clip']]['words'] += len(c['words'])
    built = {'population': population, 'items': draw_set(candidates, args.size)}
    store.write_json(set_path(), built)
    return built

def play_gap(file, item):
    gap_s = (item['gapEndMs'] - item['gapStartMs']) / 1000
    length = min(gap_s + 2 * CONTEXT_S, MAX_PLAY_S)
    play_cut(file, item['gapStartMs'] / 1000 - CONTEXT_S, length)

# ---- truths ----
# Every answer given by ear becomes a truth: what was said in a clip between two times. Truths are kept
# by clip and time, not by span number, so they correct any later reference or system set: a span that
# overlaps a truth and has the truth's words as one of its readings takes that reading as the right one.
# New sets skip spans a truth already settles. vault-save backs them up, encrypted, with the audio.

TRUTH_TOLERANCE_MS = 500

def clip_files():
    return {clip['id']: store.clip_audio(clip) for clip in store.clips()}

def truths_path():
    return store.root() / 'truths.jsonl'

def truths_by_clip():
    latest = {t['id']: t for t in store.read_jsonl(truths_path())}
    by_clip = {}
    for truth in latest.values():
        by_clip.setdefault(truth['clip'], []).append(truth)
    return by_clip

def settled_reading(span, begin, finish, clip_truths):
    """The words a truth says were spoken in this span, or None when no truth settles it."""
    texts = {' '.join(words) for words in span['readings'].values()}
    for truth in clip_truths:
        overlaps = truth['startMs'] <= finish + TRUTH_TOLERANCE_MS and begin <= truth['endMs'] + TRUTH_TOLERANCE_MS
        if overlaps and truth['said'] is not None and truth['said'] in texts:
            return truth['said'].split()
    return None

def said_by_answer(item, answer):
    """What an answer says was spoken in the item's stretch: text, '' for nothing, None when unknown."""
    if answer['answer'] == review_server.PICK:
        return None if answer['choice'] == review_server.NONE_OF_THESE else item['readings'][answer['choice']]['text']
    return {'r': ' '.join(item['words']), 'm': ' '.join(item['words']), 'h': '', 'w': None}[answer['answer']]

def truths_import(args):
    built = store.read_json(set_path(args.set))
    if not built:
        raise SystemExit(f'no set named {args.set}')
    if built.get('kind') == WHO_KIND:
        raise SystemExit('a who set says who spoke, not what was said: log its answers in docs/model-trials.json')
    answers = latest_answers(args.set)
    known = {t['id'] for t in store.read_jsonl(truths_path())}
    added = []
    for item in built['items']:
        answer = answers.get(item['key'])
        if not answer:
            continue
        truth_id = hashlib.sha1(f"{args.set}|{item['key']}|{answer['at']}".encode()).hexdigest()[:16]
        if truth_id in known:
            continue
        added.append({'id': truth_id, 'clip': item['clip'], 'startMs': item['gapStartMs'], 'endMs': item['gapEndMs'],
                      'said': said_by_answer(item, answer), 'answer': answer['answer'], 'choice': answer.get('choice'),
                      'note': answer.get('note', ''), 'before': item['before'], 'after': item['after'],
                      'set': args.set, 'by': args.by, 'at': answer['at']})
    with open(truths_path(), 'a') as f:
        f.writelines(json.dumps(t) + '\n' for t in added)
    print(f"{core.counted(len(added), 'truth')} added from {args.set}")

# ---- pick a reading ----
# Two systems disagree on a span that changes the meaning; the user hears it and picks the reading that
# was said, blind (A, B, C in shuffled order). Spans are drawn evenly from three groups: the reference
# agrees with A, with B, or with neither.

def pick_groups(a, b):
    return {f'{b} = reference': lambda r: r[b] == r['ref'] and r[a] != r['ref'],
            f'{a} = reference': lambda r: r[a] == r['ref'] and r[b] != r['ref'],
            'all differ': lambda r: len({tuple(r['ref']), tuple(r[a]), tuple(r[b])}) == 3}

def pick_set(args):
    verdicts = judged()
    clip_truths = truths_by_clip()
    groups = pick_groups(args.a, args.b)
    pools = {name: [] for name in groups}
    population = {name: {'spans': 0, 'delta': 0} for name in groups}
    meeting_words = 0
    limit = (MAX_PLAY_S - 2 * CONTEXT_S) * 1000
    for clip in store.clips():
        if clip['kind'] != 'meeting':
            continue
        ref, timed, spans = spans_for(clip)
        meeting_words += len(ref)
        for span in spans:
            readings = span['readings']
            if args.a not in readings or args.b not in readings:
                continue
            before, after = span_context(ref, span['start'], span['end'])
            verdict = verdicts.get(core.judge_key(before, [' '.join(w) for w in readings.values()], after))
            group = next((name for name, test in groups.items() if test(readings)), None)
            if not verdict or not verdict['matters'] or group is None:
                continue
            population[group]['spans'] += 1
            population[group]['delta'] += core.edit_distance(readings['ref'], readings[args.a]) - core.edit_distance(readings['ref'], readings[args.b])
            if settled_reading(span, *span_window(timed, span['start'], span['end']), clip_truths.get(clip['id'], [])) is not None:
                continue
            begin, finish = span_window(timed, span['start'], span['end'])
            if finish - begin <= limit:
                pools[group].append({'clip': clip['id'], 'key': core.span_key(clip['id'], ref, span['start'], span['end']), 'group': group,
                                     'gapStartMs': begin, 'gapEndMs': finish, 'before': before, 'after': after, 'words': [],
                                     'texts': {name: ' '.join(readings[name]) for name in ('ref', args.a, args.b)}})
    rng = random.Random(args.seed)
    per_group = args.size // len(groups)
    chosen = []
    for name, pool in pools.items():
        for item in rng.sample(pool, min(per_group, len(pool))):
            distinct = sorted(set(item['texts'].values()))
            rng.shuffle(distinct)
            item['pick'] = True
            item['readings'] = [{'system': chr(ord('A') + n), 'before': item['before'], 'text': text, 'after': item['after']} for n, text in enumerate(distinct)]
            chosen.append(item)
    rng.shuffle(chosen)
    store.write_json(set_path(args.name), {'kind': PICK_KIND, 'a': args.a, 'b': args.b, 'meetingWords': meeting_words,
                                           'population': population, 'items': chosen})
    print(f"{args.name}: {core.counted(len(chosen), 'span')} drawn; groups " + ', '.join(f"{n} {p['spans']}" for n, p in population.items()))

PICK_KIND = 'pick'

def pick_summary(name):
    built = store.read_json(set_path(name))
    answered = latest_answers(name)
    a, b = built['a'], built['b']
    lines, estimated = [], 0.0
    for group, population in built['population'].items():
        picked = [(i, answered[i['key']]['choice']) for i in built['items'] if i['group'] == group and answered.get(i['key'], {}).get('answer') == review_server.PICK]
        said = [(i, i['readings'][choice]['text']) for i, choice in picked if choice != review_server.NONE_OF_THESE]
        right = collections.Counter(name for i, text in said for name in ('ref', a, b) if i['texts'][name] == text)
        none = len(picked) - len(said)
        lines.append(f"{group}: {len(picked)} picked of {population['spans']} spans; reference right {right['ref']}, {a} {right[a]}, {b} {right[b]}, none {none}")
        if said:
            per_span = sum(core.edit_distance(text.split(), i['texts'][a].split()) - core.edit_distance(text.split(), i['texts'][b].split()) for i, text in said) / len(said)
            estimated += per_span * population['spans']
        else:
            estimated += population['delta']
    scored = sum(p['delta'] for p in built['population'].values())
    words = built['meetingWords']
    lines.append(f"\n{a} minus {b} meaning errors: {scored:+d} against the reference ({100 * scored / words:+.2f} points), "
                 f"{estimated:+.0f} by your picks extrapolated to every span ({100 * estimated / words:+.2f} points)")
    return '\n'.join(lines)

# ---- who said it ----
# Two diarizers give the same words to different people. The user hears a sample of each
# voice from the same track, then the words, and says whose they are, blind (person A and
# person B in shuffled order).

WHO_KIND = 'who'

def who_set(args):
    rng = random.Random(args.seed)
    stretches, words_total = [], 0
    for clip in store.clips():
        if not clip['speakers']:
            continue
        outputs = [store.read_json(store.sub('diarizers') / name / f"{clip['id']}.json") for name in (args.a, args.b)]
        if not all(outputs):
            continue
        ref = reference(clip)
        a_labels, _ = core.speaker_labels(ref, outputs[0]['segments'])
        b_labels, _ = core.speaker_labels(ref, outputs[1]['segments'])
        texts = [w['text'] for w in ref]
        for stretch in core.disputed_stretches(a_labels, b_labels):
            first, last = ref[stretch['start']], ref[stretch['end'] - 1]
            words_total += stretch['end'] - stretch['start']
            samples = [core.voice_sample(ref, a_labels, b_labels, label, first['startMs'], WHO_SAMPLE_MIN_MS, WHO_SAMPLE_MAX_MS, WHO_JOIN_MS)
                       for label in (stretch['a'], stretch['b'])]
            if None in samples:
                continue
            voices = [(stretch['a'], samples[0]), (stretch['b'], samples[1])]
            rng.shuffle(voices)
            heard = collections.Counter(w['speaker'] for w in ref[stretch['start']:stretch['end']])
            stretches.append({'clip': clip['id'], 'key': core.span_key(clip['id'], texts, stretch['start'], stretch['end']), 'who': True,
                              'gapStartMs': first['startMs'], 'gapEndMs': last['endMs'], 'wordCount': stretch['end'] - stretch['start'],
                              'samples': [{'startMs': s, 'endMs': e} for _, (s, e) in voices], 'voices': [label for label, _ in voices],
                              'aVoice': stretch['a'], 'bVoice': stretch['b'], 'refVoice': heard.most_common(1)[0][0]})
    chosen = rng.sample(stretches, min(args.size, len(stretches)))
    store.write_json(set_path(args.name), {'kind': WHO_KIND, 'a': args.a, 'b': args.b, 'items': chosen,
                                           'population': {'stretches': len(stretches), 'words': words_total}})
    print(f"{args.name}: {core.counted(len(chosen), 'stretch', 'stretches')} of {len(stretches)} with a sample of both voices "
          f"({core.counted(words_total, 'word')} disputed in all)")

def who_summary(name):
    built = store.read_json(set_path(name))
    answered = latest_answers(name)
    sided = collections.Counter()
    words = collections.Counter()
    for item in built['items']:
        answer = answered.get(item['key'])
        if not answer or answer.get('answer') != review_server.WHO:
            continue
        heard = None if answer['choice'] == review_server.NONE_OF_THESE else item['voices'][answer['choice']]
        for side, voice in ((built['a'], item['aVoice']), (built['b'], item['bVoice']), ('the reference', item['refVoice'])):
            if heard == voice:
                sided[side] += 1; words[side] += item['wordCount']
        if heard is None:
            sided['neither'] += 1; words['neither'] += item['wordCount']
    total = sum(1 for i in built['items'] if answered.get(i['key'], {}).get('answer') == review_server.WHO)
    lines = [f"{total} of {core.counted(len(built['items']), 'stretch', 'stretches')} answered ({built['population']['stretches']} disputed, "
             f"{core.counted(built['population']['words'], 'word')})"]
    for side in (built['a'], built['b'], 'the reference', 'neither'):
        lines.append(f"{side}: {core.counted(sided[side], 'stretch', 'stretches')}, {core.counted(words[side], 'word')}")
    return '\n'.join(lines)

def review_html(args, chosen, clips):
    import io, contextlib, argparse
    kind = (store.read_json(set_path(args.set)) or {}).get('kind')
    picking = kind == PICK_KIND
    def summary():
        if kind == WHO_KIND:
            return who_summary(args.set)
        if picking:
            return pick_summary(args.set)
        out = io.StringIO()
        try:
            with contextlib.redirect_stdout(out):
                review_summary(argparse.Namespace(no_fillers=False))
        except SystemExit as stop:
            out.write(str(stop.code or ''))
        return out.getvalue().strip()
    review_server.serve(args.set, chosen, lambda item: store.clip_audio(clips[item['clip']]), answers_path(args.set),
                        lambda: latest_answers(args.set), summary,
                        WHO_CONTEXT_S if kind == WHO_KIND else PICK_CONTEXT_S if picking else CONTEXT_S, MAX_PLAY_S)

def review_set(args):
    chosen = load_set(args)['items']
    answered = latest_answers(args.set)
    clips = {c['id']: c for c in store.clips()}
    if args.html:
        return review_html(args, chosen, clips)
    if any(i.get('pick') or i.get('who') for i in chosen):
        raise SystemExit('a pick or who set is reviewed in the browser: add --html')
    todo = [i for i in chosen if i['key'] not in answered]
    print(f"{len(chosen)} spans in the set, {len(chosen) - len(todo)} answered")
    for n, item in enumerate(todo, 1):
        file = store.clip_audio(clips[item['clip']])
        gap_s = (item['gapEndMs'] - item['gapStartMs']) / 1000
        replay = True
        while True:
            print(f"\n[{n}/{len(todo)}] {item['clip']}  {item['gapStartMs'] / 1000:.1f}s, gap {gap_s:.1f}s" + (f", playing the first {MAX_PLAY_S - 2 * CONTEXT_S:.0f}s of it" if gap_s + 2 * CONTEXT_S > MAX_PLAY_S else ''))
            print(f"   ...{item['before']} [ {' '.join(item['words'])} ] {item['after']}...")
            if replay:
                play_gap(file, item)
                replay = False
            choice = input('   r=real speech / m=said, makes no difference / w=speech, wrong words / h=hallucination / s=skip / p=replay / q=quit > ').strip().lower()
            if choice in ('p', ''):
                replay = True
            elif choice == 'q':
                return
            elif choice == 's':
                break
            elif choice in review_server.ANSWERS:
                with open(answers_path(args.set), 'a') as f:
                    f.write(json.dumps({'key': item['key'], 'clip': item['clip'], 'answer': choice, 'at': int(time.time())}) + '\n')
                break

def review_summary(args):
    built = store.read_json(set_path())
    if not built:
        raise SystemExit(f'no set yet: run `review --set {SET_NAME}`')
    answered = latest_answers()
    items = [i for i in built['items'] if answered.get(i['key'], {}).get('answer') in review_server.ANSWERS]
    # m is real speech whose presence does not change the meaning; it counts as real here.
    real = [i for i in items if answered[i['key']]['answer'] in ('r', 'm')]
    minor = [i for i in items if answered[i['key']]['answer'] == 'm']
    wrong = [i for i in items if answered[i['key']]['answer'] == 'w']
    def words(group):
        return sum(len(i['words']) for i in group)
    if not items:
        raise SystemExit('no answers yet')
    population = built['population']
    pop_words = sum(p['words'] for p in population.values())
    print(f"{core.counted(len(items), 'span')} answered of {len(built['items'])}: {len(real)} real speech ({len(minor)} not changing the meaning), {len(wrong)} speech with wrong words, {len(items) - len(real) - len(wrong)} hallucination "
          f"({100 * len(real) / len(items):.0f}% of spans, {100 * words(real) / max(1, words(items)):.0f}% of {core.counted(words(items), 'word')})")
    print(f"the set draws on {core.counted(sum(p['spans'] for p in population.values()), 'span')} / {core.counted(pop_words, 'word')} that fluid-ultra adds alone\n")
    overall = words(real) / max(1, words(items))
    expected = 0.0
    for clip_id, p in population.items():
        here = [i for i in items if i['clip'] == clip_id]
        share = words([i for i in here if answered[i['key']]['answer'] == 'r']) / words(here) if here else overall
        expected += share * p['words']
    inserted_real = collections.defaultdict(dict)
    for i in real:
        inserted_real[i['clip']][i['refIndex']] = inserted_real[i['clip']].get(i['refIndex'], []) + i['words']
    base = collections.defaultdict(lambda: [0, 0])
    sample = collections.defaultdict(lambda: [0, 0])
    for clip in store.clips():
        if clip['kind'] != 'meeting':
            continue
        ref, _, _ = spans_for(clip)
        texts = system_texts(clip)
        grown = core.apply_decisions(ref, {(at, at): ws for at, ws in inserted_real[clip['id']].items()})
        for name in (SET_SYSTEM, SET_OTHER):
            if name not in texts:
                continue
            for rows, reference_words in ((base, ref), (sample, grown)):
                scored_ref = core.drop_fillers(reference_words) if args.no_fillers else reference_words
                hyp = core.drop_fillers(texts[name]) if args.no_fillers else texts[name]
                errors, count = core.wer_counts(scored_ref, hyp)
                rows[name][0] += errors; rows[name][1] += count
    print(f"meeting WER{' without fillers' if args.no_fillers else ''}: now / real-speech insertions counted as correct (answered spans only) / extrapolated to all {pop_words:,} words")
    for name in (SET_SYSTEM, SET_OTHER):
        errors, count = base[name]
        known_errors, known_count = sample[name]
        est_errors = errors - expected if name == SET_SYSTEM else errors + expected
        print(f"{name:14} {100 * errors / max(1, count):5.2f}%  ->  {100 * known_errors / max(1, known_count):5.2f}%  ->  {100 * est_errors / max(1, count + expected):5.2f}%")
    print("extrapolation weights each clip's population by that clip's answered share; the set favours wide gaps and 2+ word runs, so it leans toward real speech")

# ---- score ----

def decisions_by_clip():
    latest = {}
    for d in store.read_jsonl(store.root() / 'decisions.jsonl'):
        latest[d['key']] = d
    by_clip = {}
    for d in latest.values():
        by_clip.setdefault(d['clip'], []).append(d)
    return by_clip

def corrected(clip, ref, timed, spans, decisions, clip_truths):
    """The reference with hand decisions and truths applied, and {(start, end): words} of what was applied."""
    keys = {core.span_key(clip['id'], ref, s['start'], s['end']): s for s in spans}
    chosen = {(keys[d['key']]['start'], keys[d['key']]['end']): core.tokens(d['text']) for d in decisions if d['key'] in keys}
    for span in spans:
        said = settled_reading(span, *span_window(timed, span['start'], span['end']), clip_truths)
        if said is not None:
            chosen.setdefault((span['start'], span['end']), said)
    return core.apply_decisions(ref, chosen), chosen

def meaning_errors(ref, fixed, spans, texts, verdicts):
    """{system: errors inside spans judged to change the meaning}, and how many spans are unjudged."""
    errors, unjudged = collections.Counter(), 0
    for span in spans:
        before, after = span_context(ref, span['start'], span['end'])
        verdict = verdicts.get(core.judge_key(before, [' '.join(words) for words in span['readings'].values()], after))
        if verdict is None:
            unjudged += 1
            continue
        if not verdict['matters']:
            continue
        right = fixed.get((span['start'], span['end']), span['readings']['ref'])
        for name in texts:
            errors[name] += core.edit_distance(right, span['readings'][name])
    return errors, unjudged

def score(args):
    totals = {}
    reviewed = checked = 0
    diar = {}
    decisions = decisions_by_clip()
    clip_truths = truths_by_clip()
    verdicts = judged() if args.meaning else {}
    meaning, unjudged_spans = collections.Counter(), 0
    for clip in store.clips():
        ref, timed, spans = spans_for(clip)
        fixed, decided = corrected(clip, ref, timed, spans, decisions.get(clip['id'], []), clip_truths.get(clip['id'], []))
        reviewed += len(decided); checked += len(spans)
        if args.meaning:
            errors, unjudged = meaning_errors(ref, decided, spans, system_texts(clip), verdicts)
            unjudged_spans += unjudged
            for name, count in errors.items():
                meaning[(name, clip['kind'])] += count
        scored_ref = core.drop_fillers(fixed) if args.no_fillers else fixed
        for name, words in system_texts(clip).items():
            subs, dels, ins = core.wer_breakdown(scored_ref, core.drop_fillers(words) if args.no_fillers else words)
            row = totals.setdefault((name, clip['kind']), [0, 0, 0, 0, 0, 0])
            row[0] += subs + dels + ins; row[1] += len(scored_ref); row[2] += 1
            row[3] += subs; row[4] += dels; row[5] += ins
        if clip['speakers']:
            for folder in sorted(store.sub('diarizers').iterdir()):
                data = store.read_json(folder / f"{clip['id']}.json")
                if data:
                    row = diar.setdefault(folder.name, [0, 0, 0, 0, 0, 0])
                    wrong, count, ref_speakers, found = core.wrong_speaker(reference(clip), data['segments'])
                    row[0] += wrong; row[1] += count; row[2] += 1
                    row[3] += found == ref_speakers; row[4] += ref_speakers; row[5] += found
    print(f"{core.counted(reviewed, 'span')} hand-checked of {checked:,} that differ; the rest keep AssemblyAI's reading")
    if args.no_fillers:
        print(f"fillers ({', '.join(sorted(core.FILLERS))}) dropped from both sides")
    print()
    for (name, kind), (errors, count, clips_n, subs, dels, ins) in sorted(totals.items()):
        detail = f"; {subs:,} S, {dels:,} D, {ins:,} I" if kind == 'meeting' else ''
        print(f"{name:14} {kind:9} WER {100 * errors / max(1, count):5.2f}%  ({core.counted(errors, 'error')} in {core.counted(count, 'word')}, {core.counted(clips_n, 'clip')}{detail})")
        if args.meaning:
            print(f"{'':14} {'':9} meaning WER {100 * meaning[(name, kind)] / max(1, count):5.2f}%  (errors in spans that change the meaning)")
    for name, (wrong, count, clips_n, right, _, _) in sorted(diar.items()):
        print(f"{name:14} speakers  {100 * wrong / max(1, count):5.2f}% of words under the wrong speaker  ({core.counted(wrong, 'word')} of {count:,}, right number of people on {right} of {core.counted(clips_n, 'clip')})")
    if args.meaning:
        print(f"\n{core.counted(unjudged_spans, 'span')} not judged yet; run judge-export, judge the file, judge-import")
    if not totals and not diar:
        print('no system output yet: run `run <system>` first')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='cmd', required=True)
    b = sub.add_parser('build', help='pick clips and fetch AssemblyAI references (needs ASSEMBLYAI_API_KEY)')
    b.add_argument('--dictations', type=int, default=DICTATION_LIMIT)
    b.add_argument('--limit', type=int, default=0, help='keep only the first N clips (meetings come first)')
    b.add_argument('--keep', action='store_true', help='reuse clips.json instead of choosing clips again')
    r = sub.add_parser('run', help='transcribe or diarize every clip with a named system')
    r.add_argument('system'); r.add_argument('--force', action='store_true')
    r.add_argument('--like', metavar='SYSTEM', help='run only the clips SYSTEM has output for, so the two score on the same set')
    sub.add_parser('disagree', help='write review.jsonl: only the spans where systems differ')
    v = sub.add_parser('review', help='play each undecided span and record the right reading')
    v.add_argument('--set', help='review a focused set (<name>.json in the reference dir) instead of the disagreement spans')
    v.add_argument('--between', nargs=2, metavar=('A', 'B'), help='ask only about spans where systems A and B differ, dictations first')
    v.add_argument('--html', action='store_true', help='with --set: review in a browser page served on 127.0.0.1')
    v.add_argument('--size', type=int, default=SET_SIZE, help='spans in a newly built set')
    v.add_argument('--rebuild', action='store_true', help='draw the set again (old answers no longer match)')
    sc = sub.add_parser('score', help='WER and wrong-speaker rate against the corrected reference')
    sc.add_argument('--no-fillers', action='store_true', help='drop um, uh, er... from both sides before aligning')
    sc.add_argument('--meaning', action='store_true', help='also count only errors in spans judged to change the meaning')
    ps = sub.add_parser('pick-set', help='draw spans that change the meaning where systems A and B disagree, to pick the reading that was said')
    ps.add_argument('name'); ps.add_argument('--a', required=True); ps.add_argument('--b', required=True)
    ps.add_argument('--size', type=int, default=SET_SIZE); ps.add_argument('--seed', type=int, default=SET_SEED)
    ws = sub.add_parser('who-set', help='draw stretches two diarizers give to different people, to say by ear whose they are')
    ws.add_argument('name'); ws.add_argument('--a', required=True); ws.add_argument('--b', required=True)
    ws.add_argument('--size', type=int, default=SET_SIZE); ws.add_argument('--seed', type=int, default=SET_SEED)
    ti = sub.add_parser('truths-import', help="turn a set's answers into truths (truths.jsonl), which every later score applies")
    ti.add_argument('set'); ti.add_argument('--by', required=True, help='who listened')
    sub.add_parser('vault-save', help='encrypt truths and their audio snippets into Scripts/asr-eval/vault (needs ASR_EVAL_VAULT_KEY)')
    sub.add_parser('vault-load', help='decrypt the vault: missing truths into truths.jsonl, snippets into vault-snippets/')
    je = sub.add_parser('judge-export', help='write the disputed spans not yet judged for meaning to a jsonl file')
    je.add_argument('--out', required=True)
    ji = sub.add_parser('judge-import', help='add judgements ({judgeKey, matters, kind, note} per line) to judgements.jsonl')
    ji.add_argument('file'); ji.add_argument('--by', required=True, help='who judged, e.g. opus-5.5')
    rs = sub.add_parser('review-summary', help='what the %s answers say about meeting WER' % SET_NAME)
    rs.add_argument('--no-fillers', action='store_true')
    args = parser.parse_args()
    {'build': build, 'run': run, 'disagree': disagree, 'review': review, 'score': score, 'review-summary': review_summary,
     'judge-export': judge_export, 'judge-import': judge_import, 'pick-set': pick_set, 'who-set': who_set, 'truths-import': truths_import,
     'vault-save': lambda _: vault.save(store.read_jsonl(truths_path()), clip_files()),
     'vault-load': lambda _: vault.load(truths_path(), store.root() / 'vault-snippets')}[args.cmd](args)

if __name__ == '__main__':
    main()
