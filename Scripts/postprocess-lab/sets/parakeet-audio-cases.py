#!/usr/bin/env python3
"""Builds cases-parakeet-audio.json: the clean-up eval with each input replaced by
what the app's recogniser heard when that input was spoken.

Inputs come from the speech-recognition rig: items.json lists one synthesised clip
per distinct eval input ({"id", "path", "input"}; `say -v Daniel`, 16 kHz), and
transcripts.json is the tcpp tool's output for those clips ({"id", "text"}, and
"words": [{"w", "c"}] when it was run with confidences). Expected outputs are
unchanged. The typed input's confidence map is replaced by the recogniser's
(lowest score per token); without "words", every word counts as confident.

usage: parakeet-audio-cases.py <items.json> <transcripts.json> <cases.json> <out.json>
"""
import json, sys

items_path, transcripts_path, cases_path, out_path = sys.argv[1:]
heard = {o['id']: o for o in json.load(open(transcripts_path))}
by_input = {}
for item in json.load(open(items_path)):
    by_input.setdefault(item['input'], heard[item['id']])
out = []
for case in json.load(open(cases_path)):
    case = dict(case)
    transcript = by_input[case['input']]
    case['input'] = transcript['text']
    case.pop('confidence', None)
    scores = {}
    for word in transcript.get('words', []):
        if word['c'] >= 0:
            scores[word['w']] = min(word['c'], scores.get(word['w'], 1))
    if scores:
        case['confidence'] = scores
    out.append(case)
json.dump(out, open(out_path, 'w'), indent=1)
unpunctuated = sum(1 for c in out if not any(ch in c['input'] for ch in '.,?!'))
print(f"{len(out)} cases, {unpunctuated} heard without punctuation")
