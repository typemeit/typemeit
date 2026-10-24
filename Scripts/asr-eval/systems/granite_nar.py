"""IBM Granite Speech 4.1 2B NAR (Apache-2.0) as the handy-computer Q8_0 GGUF, run by transcribe.cpp's
transcribe-cli on Metal. prepare() clones transcribe.cpp at COMMIT into build/ and downloads the weights
there (both git-ignored). The model takes at most about 6 minutes per call, so every clip is cut at its
quietest 50 ms within the last 5 s before CHUNK_SECONDS (vad.split_long; nothing is dropped, as in the
app's own chunk loop). Dictations and meeting tracks run as separate --batch processes, each loading
the model once; per-clip ms is transcribe-cli's mel + encode + decode, and CPU % and GPU device
utilisation are sampled once a second while each process runs."""
import json, os, pathlib, re, subprocess, tempfile, threading, wave
import numpy as np
import store
from . import fluid_common, vad

NAME = 'granite-nar'
CHUNK_SECONDS = 120
COMMIT = 'b61b7f936e4e728f8999a8c3e98c7112e700410e'
SOURCE = fluid_common.REPO / 'build/asr-eval-transcribe.cpp'
CLI = SOURCE / 'build/bin/transcribe-cli'
WEIGHTS_URL = 'https://huggingface.co/handy-computer/granite-speech-4.1-2b-nar-gguf/resolve/main/granite-speech-4.1-2b-nar-Q8_0.gguf'
WEIGHTS = fluid_common.REPO / 'build/asr-eval-models/granite-nar/granite-speech-4.1-2b-nar-Q8_0.gguf'
PCM_SCALE = 32768.0

def prepare():
    if not CLI.exists():
        if not SOURCE.exists():
            subprocess.run(['git', 'clone', '-q', 'https://github.com/handy-computer/transcribe.cpp', str(SOURCE)], check=True)
        subprocess.run(['git', '-C', str(SOURCE), 'checkout', '-q', COMMIT], check=True)
        subprocess.run(['cmake', '-S', str(SOURCE), '-B', str(SOURCE / 'build'), '-DCMAKE_BUILD_TYPE=Release'], check=True)
        subprocess.run(['cmake', '--build', str(SOURCE / 'build'), '-j', '8', '--target', 'transcribe-cli'], check=True)
    if not WEIGHTS.exists():
        WEIGHTS.parent.mkdir(parents=True, exist_ok=True)
        partial = str(WEIGHTS) + '.part'
        subprocess.run(['curl', '-sfL', '-o', partial, WEIGHTS_URL], check=True)
        os.replace(partial, WEIGHTS)

def gpu_utilisation():
    listing = subprocess.run(['ioreg', '-r', '-c', 'IOAccelerator'], capture_output=True, text=True).stdout
    found = re.search(r'"Device Utilization %"=(\d+)', listing)
    return int(found.group(1)) if found else None

def sample_load(time_pid, cpu_samples, gpu_samples, stopped):
    """time_pid is /usr/bin/time's; the CPU % sampled is its child's, transcribe-cli."""
    while not stopped.wait(1.0):
        child_pid = subprocess.run(['pgrep', '-P', str(time_pid)], capture_output=True, text=True).stdout.strip()
        cpu = subprocess.run(['ps', '-o', '%cpu=', '-p', child_pid], capture_output=True, text=True).stdout.strip() if child_pid else ''
        if cpu:
            cpu_samples.append(float(cpu))
        gpu = gpu_utilisation()
        if gpu is not None:
            gpu_samples.append(gpu)

def run_batch(chunk_paths):
    """Transcribes chunk_paths in one transcribe-cli process: ({path: row}, load_ms, peak_bytes, load_summary)."""
    with tempfile.TemporaryDirectory() as tmp:
        listing = os.path.join(tmp, 'chunks.list')
        # The first file runs on cold Metal pipelines (about 1 s on a 3 s dictation), so it runs
        # twice and the later row, the warm one, is kept.
        pathlib.Path(listing).write_text(''.join(p + '\n' for p in chunk_paths[:1] + chunk_paths))
        process = subprocess.Popen(['/usr/bin/time', '-l', str(CLI), '-q', '-m', str(WEIGHTS), '--batch', listing, '--batch-jsonl'],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        cpu_samples, gpu_samples, stopped = [], [], threading.Event()
        sampler = threading.Thread(target=sample_load, args=(process.pid, cpu_samples, gpu_samples, stopped))
        sampler.start()
        output, errors = process.communicate()
        stopped.set()
        sampler.join()
    # ggml's Metal teardown can assert at exit after every line is written, so the exit status
    # says nothing; a missing row does.
    rows_by_path, load_ms = {}, None
    for line in output.splitlines():
        if not line.startswith('{'):
            continue
        row = json.loads(line)
        if row.get('type') == 'batch_header':
            load_ms = row['load_ms']
        elif 'file' in row:
            rows_by_path[row['file']] = row
    missing = [p for p in chunk_paths if p not in rows_by_path]
    if missing:
        raise SystemExit(f'{NAME}: no row for {len(missing)} of {len(chunk_paths)} chunks (exit {process.returncode}): {errors[-2000:]}')
    peak = re.search(r'(\d+)\s+maximum resident set size', errors)
    load = {'cpuPercent': summary(cpu_samples), 'gpuPercent': summary(gpu_samples)}
    return rows_by_path, load_ms, int(peak.group(1)) if peak else None, load

def summary(samples):
    return {'mean': round(sum(samples) / len(samples), 1), 'peak': max(samples), 'samples': len(samples)} if samples else None

def cut(wav_path, clip_id, out_dir):
    """Writes the clip as pieces of at most CHUNK_SECONDS cut at quiet points; {'paths', 'audioSeconds'}."""
    with wave.open(wav_path) as source:
        rate = source.getframerate()
        audio = np.frombuffer(source.readframes(source.getnframes()), dtype=np.int16).astype(np.float32) / PCM_SCALE
    vad.MAX_CHUNK_SECONDS = CHUNK_SECONDS
    paths = []
    for n, piece in enumerate(vad.split_long(audio)):
        piece = np.pad(piece, (0, max(0, rate - len(piece))))
        path = os.path.join(out_dir, f'{clip_id}~{n:04d}.wav')
        with wave.open(path, 'wb') as target:
            target.setnchannels(1)
            target.setsampwidth(2)
            target.setframerate(rate)
            target.writeframes((np.clip(piece, -1, 1) * (PCM_SCALE - 1)).astype(np.int16).tobytes())
        paths.append(path)
    return {'paths': paths, 'audioSeconds': len(audio) / rate}

def transcribe(items):
    prepare()
    converted = [{'id': i['id'], 'path': fluid_common.wav(i['path'], i['id'])} for i in items]
    texts, timings = {}, {}
    with tempfile.TemporaryDirectory() as tmp:
        manifest = {c['id']: cut(c['path'], c['id'], tmp) for c in converted}
        for kind, prefix in (('dictation', 'd-'), ('meeting', 'm-')):
            clip_ids = [i['id'] for i in converted if i['id'].startswith(prefix)]
            if not clip_ids:
                continue
            rows_by_path, load_ms, peak_bytes, load = run_batch([p for c in clip_ids for p in manifest[c]['paths']])
            clip_timings = []
            for clip_id in clip_ids:
                chunk_rows = [rows_by_path[p] for p in manifest[clip_id]['paths']]
                texts[clip_id] = ' '.join(r['text'].strip() for r in chunk_rows).strip()
                clip_timings.append({'id': clip_id, 'audioSeconds': manifest[clip_id]['audioSeconds'],
                                     'ms': round(sum(r['mel_ms'] + r['encode_ms'] + r['decode_ms'] for r in chunk_rows), 1)})
            timings[kind] = {'peakBytes': peak_bytes, 'loadSeconds': load_ms / 1000 if load_ms else None, 'clips': clip_timings,
                             'chunks': {c: len(manifest[c]['paths']) for c in clip_ids}, **load}
            audio_s = sum(c['audioSeconds'] for c in clip_timings)
            busy_s = sum(c['ms'] for c in clip_timings) / 1000
            print(f"{NAME} {kind}: {audio_s / max(busy_s, 1e-9):.0f}x realtime, peak {peak_bytes / 2**30 if peak_bytes else 0:.2f} GiB, "
                  f"CPU {load['cpuPercent']}, GPU {load['gpuPercent']}")
    path = store.sub('timings') / f'{NAME}.json'
    merged = store.read_json(path, {})
    merged.update(timings)
    store.write_json(path, merged)
    return texts
