"""Per-window diagnosis of plain cohere hallucination. Runs in build/asr-eval-venv.
usage: diagnose_cohere.py OUT_JSON CLIP_ID... ; prints numbers only, never text."""
import json, pathlib, sys
import numpy as np, soundfile, mlx.core as mx
sys.path.insert(0, str(pathlib.Path(__file__).parent / 'systems'))
import vad
from mlx_speech.generation import CohereAsrModel
MODELS = pathlib.Path(__file__).resolve().parents[2] / 'build/asr-eval-models/mlx-int8'
import os
WAV = pathlib.Path.home() / 'Library/Application Support/TypeMeIt/asr-reference/wav'
mx.set_cache_limit(1 << 30)
model = CohereAsrModel.from_path(str(MODELS))
def windows(audio, rate, W=30.0, S=5.0, F=0.05):
    window, search, frame = int(W * rate), int(S * rate), int(F * rate)
    start = 0
    while len(audio) - start > window:
        tail = audio[start + window - search:start + window]
        frames = len(tail) // frame
        energy = (tail[:frames * frame].reshape(frames, frame) ** 2).mean(axis=1)
        cut = start + window - search + int(energy.argmin()) * frame + frame // 2
        yield start, audio[start:cut]
        start = cut
    yield start, audio[start:]
result = {}
for clip in sys.argv[2:]:
    audio, rate = soundfile.read(WAV / f'{clip}.wav', dtype='float32')
    regions = vad.speech_regions(audio)
    rows = []
    for start, piece in windows(audio, rate):
        b, e = start / rate, (start + len(piece)) / rate
        speech = sum(max(0, min(e, r1) - max(b, r0)) for r0, r1 in regions)
        words = len(model.transcribe(piece, sample_rate=rate, language='en').text.split())
        mx.clear_cache()
        rows.append({'start': b, 'seconds': e - b, 'speech_fraction': speech / (e - b), 'words': words})
    result[clip] = rows
    print(clip, len(rows), 'windows', flush=True)
json.dump(result, open(sys.argv[1], 'w'))
