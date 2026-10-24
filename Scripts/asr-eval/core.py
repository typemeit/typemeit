"""Pure logic: tokenising, alignment, disagreement spans, WER, wrong-speaker rate.
No I/O, so tests run on fixture text."""
import difflib, hashlib, itertools, re

def tokens(text):
    return re.findall(r"[a-z0-9']+", text.lower().replace('’', "'"))

FILLERS = frozenset({'um', 'uh', 'er', 'erm', 'ah', 'hmm', 'mm'})

def drop_fillers(words):
    return [w for w in words if w not in FILLERS]

def counted(n, singular, plural=None):
    return f"{n:,} {singular if n == 1 else plural or singular + 's'}"

def opcodes(ref, hyp):
    """Non-equal blocks of hyp against ref as (ref_start, ref_end, hyp_start, hyp_end),
    plus (lo, hi): ref boundary -> hyp index where a span starting / ending there begins / ends,
    for every boundary outside a block's interior. They differ only at an insertion point."""
    matcher = difflib.SequenceMatcher(None, ref, hyp, autojunk=False)
    blocks, lo, hi = [], {}, {}
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag == 'equal':
            for k in range(i2 - i1 + 1):
                hi[i1 + k] = j1 + k
                if k > 0 or i1 not in lo:
                    lo[i1 + k] = j1 + k
        else:
            blocks.append((i1, i2, j1, j2))
            lo[i1] = j1
            hi[i2] = j2
    if not ref and not hyp:
        lo[0] = hi[0] = 0
    return blocks, (lo, hi)

def disagreements(ref, systems):
    """ref: list of words. systems: {name: list of words}. Returns spans
    [{start, end, readings: {name: [words]}}] over ref[start:end]; the reference's own
    reading is under the key given by the caller as 'ref' (added here as 'ref')."""
    aligned = {name: opcodes(ref, words) for name, words in systems.items()}
    ranges = sorted((i1, i2) for blocks, _ in aligned.values() for i1, i2, _, _ in blocks)
    merged = []
    for start, end in ranges:
        if merged and start <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], end)
        else:
            merged.append([start, end])
    spans = []
    for start, end in merged:
        readings = {'ref': ref[start:end]}
        for name, words in systems.items():
            lo, hi = aligned[name][1]
            readings[name] = words[lo[start]:hi[end]]
        spans.append({'start': start, 'end': end, 'readings': readings})
    return spans

# Kinds a meaning judge gives a disputed span; the first five never change what was meant.
UNCHANGED_MEANING = ('filler', 'repeat', 'false_start', 'function_word', 'form')
JUDGE_KINDS = UNCHANGED_MEANING + ('content', 'name', 'negation')

def judge_key(before, reading_texts, after):
    """Content hash of a disputed span: the same words around the same competing readings get the
    same key whichever reference or system set produced the span, so a judgement is made once."""
    return hashlib.sha1('|'.join([before, *sorted(set(reading_texts)), after]).encode()).hexdigest()[:16]

def span_key(clip, ref, start, end):
    return hashlib.sha1(f"{clip}|{start}|{end}|{' '.join(ref[start:end])}".encode()).hexdigest()[:12]

def apply_decisions(ref, decisions):
    """decisions: {(start, end): replacement words}. Returns corrected reference words."""
    out, cursor = [], 0
    for (start, end), words in sorted(decisions.items()):
        if start < cursor:
            continue
        out += ref[cursor:start] + words
        cursor = end
    return out + ref[cursor:]

def edit_distance(ref, hyp):
    row = list(range(len(hyp) + 1))
    for i in range(1, len(ref) + 1):
        prev, row[0] = row[0], i
        for j in range(1, len(hyp) + 1):
            cur = min(row[j] + 1, row[j - 1] + 1, prev + (ref[i - 1] != hyp[j - 1]))
            prev, row[j] = row[j], cur
    return row[len(hyp)]

def wer_breakdown(ref, hyp):
    """(substitutions, deletions, insertions) of a minimum edit alignment of hyp against ref."""
    width = len(hyp) + 1
    moves = [bytearray(width) for _ in range(len(ref) + 1)]  # 0 match/sub, 1 delete, 2 insert
    row = list(range(width))
    moves[0][1:] = b'\x02' * len(hyp)
    for i in range(1, len(ref) + 1):
        prev, row[0] = row[0], i
        moves[i][0] = 1
        for j in range(1, width):
            diag = prev + (ref[i - 1] != hyp[j - 1])
            delete, insert = row[j] + 1, row[j - 1] + 1
            best = min(diag, delete, insert)
            moves[i][j] = 0 if best == diag else 1 if best == delete else 2
            prev, row[j] = row[j], best
    i, j = len(ref), len(hyp)
    subs = dels = ins = 0
    while i or j:
        move = moves[i][j]
        if move == 0:
            subs += ref[i - 1] != hyp[j - 1]
            i, j = i - 1, j - 1
        elif move == 1:
            dels += 1
            i -= 1
        else:
            ins += 1
            j -= 1
    return subs, dels, ins

def wer_counts(ref, hyp):
    return edit_distance(ref, hyp), len(ref)

def _label_at(midpoint, segments):
    covering = [s for s in segments if s['startMs'] <= midpoint < s['endMs']]
    if covering:
        return min(covering, key=lambda s: s['endMs'] - s['startMs'])['speaker']
    if not segments:
        return None
    nearest = min(segments, key=lambda s: min(abs(midpoint - s['startMs']), abs(midpoint - s['endMs'])))
    return nearest['speaker']

def speaker_labels(words, segments):
    """words: [{startMs, endMs, speaker}] with the reference's labels. segments: a
    diarizer's [{startMs, endMs, speaker}]. Each word takes the label of the segment
    covering its midpoint (the nearest segment if none does). Labels are matched to the
    reference's by the assignment that agrees on the most words. Returns (the reference
    label each word gets, None where its label matches nothing; labels the diarizer found)."""
    heard = [_label_at((w['startMs'] + w['endMs']) / 2, segments) for w in words]
    ref_labels = sorted({w['speaker'] for w in words})
    hyp_labels = sorted({h for h in heard if h is not None})
    overlap = {(h, r): 0 for h in hyp_labels for r in ref_labels}
    for h, w in zip(heard, words):
        if h is not None:
            overlap[(h, w['speaker'])] += 1
    best, best_score = {}, -1
    n = min(len(hyp_labels), len(ref_labels))
    for hyps in itertools.combinations(hyp_labels, n):
        for refs in itertools.permutations(ref_labels, n):
            score = sum(overlap[(h, r)] for h, r in zip(hyps, refs))
            if score > best_score:
                best, best_score = dict(zip(hyps, refs)), score
    return [best.get(h) for h in heard], len(hyp_labels)

def wrong_speaker(words, segments):
    """Words a diarizer puts under another speaker than the reference (speaker_labels).
    Returns (wrong words, words, reference speakers, found speakers)."""
    labels, found = speaker_labels(words, segments)
    wrong = sum(1 for label, w in zip(labels, words) if label != w['speaker'])
    return wrong, len(words), len({w['speaker'] for w in words}), found

def disputed_stretches(a_labels, b_labels):
    """Runs of consecutive words two diarizers give to different reference speakers, both
    of them a speaker the reference has. Returns [{start, end, a, b}], end exclusive."""
    stretches = []
    for i, (a, b) in enumerate(zip(a_labels, b_labels)):
        if a is None or b is None or a == b:
            continue
        last = stretches[-1] if stretches else None
        if last and last['end'] == i and (last['a'], last['b']) == (a, b):
            last['end'] = i + 1
        else:
            stretches.append({'start': i, 'end': i + 1, 'a': a, 'b': b})
    return stretches

def voice_sample(words, a_labels, b_labels, speaker, near_ms, min_ms, max_ms, join_ms):
    """The (startMs, endMs) of the run of `speaker`'s words nearest `near_ms` that the
    reference and both diarizers agree on, at least `min_ms` long, cut to `max_ms`.
    Words less than `join_ms` apart are one run. None when there is no such run."""
    runs, run = [], []
    for w, a, b in zip(words, a_labels, b_labels):
        agreed = w['speaker'] == a == b == speaker
        if agreed and run and w['startMs'] - run[-1]['endMs'] < join_ms:
            run.append(w)
            continue
        if run:
            runs.append(run)
        run = [w] if agreed else []
    if run:
        runs.append(run)
    long_enough = [(r[0]['startMs'], r[-1]['endMs']) for r in runs if r[-1]['endMs'] - r[0]['startMs'] >= min_ms]
    if not long_enough:
        return None
    start, end = min(long_enough, key=lambda run: abs(run[0] - near_ms))
    return start, min(end, start + max_ms)

def lone_insertions(ref, hyp, other):
    """Runs of hyp words that hyp adds beside ref and also beside other (pure insertions
    against both, neither of them has the words). Returns [{refIndex, hypStart, words}],
    refIndex being the ref boundary the run sits at."""
    def inserted(base):
        return {j for i1, i2, j1, j2 in opcodes(base, hyp)[0] if i1 == i2 for j in range(j1, j2)}
    both = inserted(other)
    runs = []
    for i1, i2, j1, j2 in opcodes(ref, hyp)[0]:
        if i1 != i2:
            continue
        run = []
        for j in range(j1, j2 + 1):
            if j < j2 and j in both:
                run.append(j)
            elif run:
                runs.append({'refIndex': i1, 'hypStart': run[0], 'words': [hyp[k] for k in run]})
                run = []
    return runs
