"""Shared runner for diarizers behind Scripts/asr-eval/diar/run.sh. The track is converted to a
16 kHz mono WAV first; per-clip timings (model load excluded) go to timings/<name>.json."""
import hashlib, json, pathlib, subprocess
import store

RUN = pathlib.Path(__file__).resolve().parents[1] / 'diar' / 'run.sh'

def diarize_with(system, name, path):
    clip_id = hashlib.sha256(str(path).encode()).hexdigest()[:12]
    target = store.sub('wav') / f'{clip_id}.wav'
    if not target.exists():
        subprocess.run(['ffmpeg', '-v', 'error', '-y', '-i', str(path), '-ac', '1', '-ar', '16000', str(target)], check=True)
    stdout = subprocess.run([str(RUN), system, str(target)], capture_output=True, text=True, check=True).stdout
    # FluidAudio's offline pipeline can print to stdout after the result; the result is the first value.
    out, end = json.JSONDecoder().raw_decode(stdout)
    if stdout[end:].strip():
        print(f'{name}: ignored after the result: {stdout[end:].strip()[:200]}')
    timings = store.sub('timings') / f'{name}.json'
    merged = store.read_json(timings, {})
    merged[clip_id] = {k: out[k] for k in ('loadSeconds', 'runSeconds', 'audioSeconds')}
    store.write_json(timings, merged)
    return out['segments']
