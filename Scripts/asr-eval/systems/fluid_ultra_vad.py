"""fluid-ultra fed Silero speech chunks (vad.py) instead of whole tracks, so FluidAudio never chunks
long audio itself. Each chunk is at most CHUNK_SECONDS, under Ultra's 15 s window
(ASRConstants.maxModelSamples = 240,000 samples), so every chunk is one encoder pass.
Variants: fluid-ultra-vad (14.5 s) and fluid-ultra-vad10 (10 s)."""
import json, os, subprocess, tempfile
import store
from . import cohere, fluid_common

NAME = 'fluid-ultra-vad'
CHUNK_SECONDS = 14.5
HELPER = os.path.join(os.path.dirname(__file__), 'fluid_vad_chunks.py')

def transcribe_chunked(name, chunk_seconds, items, vad_overrides=None, version='ultra'):
    python = cohere.prepare()
    cli = fluid_common.binary()
    converted = [{'id': i['id'], 'path': fluid_common.wav(i['path'], i['id'])} for i in items]
    texts, timings = {}, {}
    with tempfile.TemporaryDirectory() as tmp:
        listing, manifest_path = os.path.join(tmp, 'clips.json'), os.path.join(tmp, 'manifest.json')
        json.dump(converted, open(listing, 'w'))
        subprocess.run([python, HELPER, str(chunk_seconds), listing, os.path.join(tmp, 'chunks'), manifest_path, json.dumps(vad_overrides or {})], check=True)
        manifest = json.load(open(manifest_path))
        for kind, prefix in (('dictation', 'd-'), ('meeting', 'm-')):
            ids = [i['id'] for i in converted if i['id'].startswith(prefix)]
            pieces = [{'id': f'{c}~{n:04d}', 'path': p} for c in ids for n, p in enumerate(manifest[c]['paths'])]
            if not pieces:
                continue
            result = fluid_common.run_group(cli, version, pieces)
            by_piece = {c['id']: c for c in result['clips']}
            clips = []
            for c in ids:
                parts = [by_piece[f'{c}~{n:04d}'] for n in range(len(manifest[c]['paths']))]
                texts[c] = ' '.join(p['text'].strip() for p in parts).strip()
                clips.append({'id': c, 'ms': sum(p['ms'] for p in parts) + 1000 * manifest[c]['vadSeconds'],
                              'audioSeconds': manifest[c]['audioSeconds']})
            timings[kind] = {'peakBytes': result['peakBytes'], 'loadSeconds': result['loadSeconds'], 'clips': clips,
                             'chunks': {c: len(manifest[c]['paths']) for c in ids}}
    path = store.sub('timings') / f'{name}.json'
    merged = store.read_json(path, {})
    merged.update(timings)
    store.write_json(path, merged)
    return texts

def transcribe(items):
    return transcribe_chunked(NAME, CHUNK_SECONDS, items)
