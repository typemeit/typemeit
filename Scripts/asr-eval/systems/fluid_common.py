"""Shared runner for systems behind a CLI that takes <items.json> <out.json>: the FluidAudio
Parakeet-family candidates (fluid-ultra, fluid-phonon2) via Scripts/asr-eval/fluidasr, and the
shipped app path (shipped) via Scripts/asr-app-path. Dictations and meeting tracks run as separate processes so each has its own peak
memory; per-clip timings (warm model, load excluded) go to timings/<name>.json in the reference dir."""
import json, os, pathlib, subprocess, tempfile
import store

REPO = pathlib.Path(__file__).resolve().parents[3]

PACKAGE = pathlib.Path(__file__).resolve().parents[1] / 'fluidasr'
SCRATCH = REPO / 'build/asr-eval-fluidasr'

def binary():
    subprocess.run(['swift', 'build', '-c', 'release', '--package-path', str(PACKAGE), '--scratch-path', str(SCRATCH)], check=True)
    out = subprocess.run(['swift', 'build', '-c', 'release', '--package-path', str(PACKAGE), '--scratch-path', str(SCRATCH), '--show-bin-path'],
                         capture_output=True, text=True, check=True).stdout.strip()
    return os.path.join(out, 'fluidasr')

def wav(path, clip_id):
    target = store.sub('wav') / f'{clip_id}.wav'
    if not target.exists():
        subprocess.run(['ffmpeg', '-v', 'error', '-y', '-i', path, '-ac', '1', '-ar', '16000', str(target)], check=True)
    return str(target)

def run_group(command, items):
    with tempfile.TemporaryDirectory() as tmp:
        listing, out = os.path.join(tmp, 'items.json'), os.path.join(tmp, 'out.json')
        json.dump(items, open(listing, 'w'))
        subprocess.run(command + [listing, out], check=True)
        return json.load(open(out))

def save_timings(name, timings):
    """Merges timings ({kind: {...}}, kind 'dictation' or 'meeting') into timings/<name>.json, so a
    run of one kind keeps the other kind's figures."""
    path = store.sub('timings') / f'{name}.json'
    merged = store.read_json(path, {})
    merged.update(timings)
    store.write_json(path, merged)

def transcribe_with(version, name, items):
    cli = binary()
    return transcribe_by(lambda kind: [cli, version], name, items)

def transcribe_by(command_for, name, items):
    converted = [{'id': i['id'], 'path': wav(i['path'], i['id'])} for i in items]
    texts, timings = {}, {}
    for kind, prefix in (('dictation', 'd-'), ('meeting', 'm-')):
        group = [i for i in converted if i['id'].startswith(prefix)]
        if not group:
            continue
        result = run_group(command_for(kind), group)
        for clip in result['clips']:
            texts[clip['id']] = clip['text']
        timings[kind] = {'peakBytes': result['peakBytes'], 'loadSeconds': result['loadSeconds'],
                         'clips': [{k: c[k] for k in ('id', 'ms', 'audioSeconds')} for c in result['clips']]}
    save_timings(name, timings)
    return texts
