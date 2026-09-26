#!/usr/bin/env python3
"""Scores AssemblyAI's Dictation API on the clean-up eval.

Each eval input is spoken with macOS `say` (Daniel, en_GB) into 16 kHz WAV and
posted to the Dictation API with the case's custom words and screen terms as
keyterms. Runs with writing styles send the style rules as `llm_instruction`;
runs without styles use the API's default clean-up. The cleaned text
(`llm_response`) is scored with a port of eval.swift's matcher, raw and with
our code passes applied on top. Responses are cached per request, so a re-run
does not call the API again.

usage: ASSEMBLYAI_API_KEY=... run.py <result.json of a baseline run> <cases.json> <codepass binary>
"""
import hashlib, json, os, re, subprocess, sys, time

import requests

HERE = os.path.dirname(os.path.abspath(__file__))
AUDIO = os.path.join(HERE, 'audio')
CACHE = os.path.join(HERE, 'cache')
URL = 'https://dictation.assemblyai.com/v1/transcribe/live'
VOICE = 'Daniel'

BASE = ("Clean up this dictated text. Remove filler sounds (um, uh, er, ah) and stutters, resolve "
        "self-corrections to what the speaker settled on, fix punctuation and capitalisation, and fix "
        "obvious mishearings. Keep every other word and the speaker's word order. Do not paraphrase, "
        "summarise, or answer questions in the text.")
STYLE_RULES = {
    'digits': "Write every number as digits (one → 1, twenty five → 25, first → 1st).",
    'fillerWords': ("Also delete the filler words like, actually, basically, literally, you know, I mean, "
                    "sort of and kind of where they add nothing; keep like as a verb or a comparison."),
    'contractions': "Use contractions wherever one exists (do not → don't, I am → I'm, it is → it's).",
    'lists': ("When the speaker counts items (first, second, third), write the lead-in on its own line and "
              "then a numbered list, one item per line (1. … 2. …)."),
    'quotes': 'Put reported speech in straight double quotes (she said ship it → she said "ship it").',
}
ORDER = ['digits', 'fillerWords', 'contractions', 'lists', 'quotes']


def instruction(styles):
    if not styles:
        return None
    return BASE + ' ' + ' '.join(STYLE_RULES[s] for s in ORDER if s in styles)


def audio_for(text):
    os.makedirs(AUDIO, exist_ok=True)
    path = os.path.join(AUDIO, hashlib.sha1(text.encode()).hexdigest()[:16] + '.wav')
    if not os.path.exists(path):
        subprocess.run(['say', '-v', VOICE, '-o', path, '--data-format=LEI16@16000', text], check=True)
    return path


def call(text, keyterms, llm_instruction):
    config = {}
    if keyterms:
        config['keyterms_prompt'] = keyterms[:100]
    if llm_instruction:
        config['llm_instruction'] = llm_instruction
    key = hashlib.sha1(json.dumps([text, config], sort_keys=True).encode()).hexdigest()[:20]
    os.makedirs(CACHE, exist_ok=True)
    cached = os.path.join(CACHE, key + '.json')
    if os.path.exists(cached):
        return json.load(open(cached))
    wav = open(audio_for(text), 'rb').read()
    t0 = time.monotonic()
    r = requests.post(URL, headers={'Authorization': os.environ['ASSEMBLYAI_API_KEY']},
                      files={'config': (None, json.dumps(config), 'application/json'),
                             'audio': ('clip.wav', wav, 'audio/wav')}, timeout=90)
    wall = (time.monotonic() - t0) * 1000
    if r.status_code != 200:
        raise SystemExit(f'HTTP {r.status_code}: {r.text[:300]}')
    body = r.json()
    body['client_ms'] = wall
    json.dump(body, open(cached, 'w'))
    return body


# The eval's matcher (eval.swift: normalise, normaliseLines, tidy).
TOKEN = re.compile(r'(?:[^\W_]|[$£€%"])+')


def normalise(s):
    return ' '.join(TOKEN.findall(s.lower()))


def normalise_lines(s):
    return '\n'.join(normalise(line) for line in s.split('\n'))


def tidy(s):
    t = s.replace('’', "'").replace('‘', "'")
    t = '\n'.join(' '.join(line.split()) for line in t.split('\n'))
    return t[:-1] if t.endswith('.') else t


def match(out, accepted, exact):
    if exact:
        return any(tidy(out) == tidy(a) for a in accepted)
    return any(normalise_lines(out) == normalise_lines(a) for a in accepted)


def pct(xs, q):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(len(xs) * q))] if xs else 0


def main():
    results = json.load(open(sys.argv[1]))
    cases = json.load(open(sys.argv[2]))
    codepass = sys.argv[3]
    exact = {(c['input'], tuple(sorted(c.get('styles', [])))): c.get('exact', False) for c in cases if not c.get('matrix')}
    words = {c['input']: c.get('customWords', []) for c in cases}
    rows = []
    for n, r in enumerate(results):
        styles = sorted(r['styles'])
        keyterms = words.get(r['input'], []) + (r.get('terms') or [])
        body = call(r['input'], keyterms, instruction(styles))
        out = body.get('llm_response') or body.get('text') or ''
        rows.append({'r': r, 'styles': styles, 'body': body, 'out': out,
                     'exact': exact.get((r['input'], tuple(styles)), False)})
        if n % 25 == 0:
            print(f'{n}/{len(results)}', file=sys.stderr)
    passed = subprocess.run([codepass], input=json.dumps([{'text': x['out'], 'styles': x['styles']} for x in rows]),
                            capture_output=True, text=True, check=True).stdout
    for x, p in zip(rows, json.loads(passed)):
        x['passed'] = p
    for label, field in [('raw llm_response', 'out'), ('+ our code passes', 'passed')]:
        normal = [x for x in rows if not x['r'].get('wish')]
        wishes = [x for x in rows if x['r'].get('wish')]
        ok = sum(match(x[field], x['r']['expected'], x['exact']) for x in normal)
        granted = sum(match(x[field], x['r']['expected'], x['exact']) for x in wishes)
        print(f'{label}: eval {ok}/{len(normal)}  wishes {granted}/{len(wishes)}')
    client = [x['body']['client_ms'] for x in rows]
    server = [x['body'].get('request_time_ms', 0) for x in rows]
    print(f'latency ms, client wall: p50 {pct(client, .5):.0f}  p95 {pct(client, .95):.0f};  server request_time: p50 {pct(server, .5):.0f}  p95 {pct(server, .95):.0f}')
    print(f'llm failures: {sum(1 for x in rows if x["body"].get("llm_error"))}')
    with open(os.path.join(HERE, 'scored.json'), 'w') as f:
        json.dump([{'input': x['r']['input'], 'styles': x['styles'], 'verbatim': x['body'].get('text'),
                    'llm_response': x['out'], 'with_code_passes': x['passed'],
                    'expected': x['r']['expected'], 'wish': x['r'].get('wish'),
                    'raw_pass': match(x['out'], x['r']['expected'], x['exact']),
                    'passes_pass': match(x['passed'], x['r']['expected'], x['exact'])} for x in rows], f, indent=1)


if __name__ == '__main__':
    main()
