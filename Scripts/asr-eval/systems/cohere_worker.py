"""Runs inside build/asr-eval-venv (Python 3.13, mlx-speech). usage: cohere_worker.py MODEL_DIR ITEMS_JSON OUT_JSON
ITEMS_JSON is [{id, path}] of 16 kHz mono WAVs. OUT_JSON is {id: {text, seconds}, "_peak_rss_mb": n}."""
import json, resource, sys, time
import numpy as np
import mlx.core as mx
import soundfile
from mlx_speech.generation import CohereAsrModel

# The model card's max_audio_clip_s is 35 s with a 5 s overlap, so a clip up to 30 s takes the model's
# single-window path. Longer audio is cut here into windows of at most WINDOW_SECONDS, each ending at
# the quietest 50 ms frame in the last SEARCH_SECONDS, and the texts are joined with a space.
WINDOW_SECONDS = 30.0
SEARCH_SECONDS = 5.0
FRAME_SECONDS = 0.05

def transcribe_window(piece, rate):
    text = model.transcribe(piece, sample_rate=rate, language='en').text.strip()
    mx.clear_cache()
    return text

def windows(audio, rate):
    window, search, frame = int(WINDOW_SECONDS * rate), int(SEARCH_SECONDS * rate), int(FRAME_SECONDS * rate)
    start = 0
    while len(audio) - start > window:
        tail = audio[start + window - search:start + window]
        frames = len(tail) // frame
        energy = (tail[:frames * frame].reshape(frames, frame) ** 2).mean(axis=1)
        cut = start + window - search + int(energy.argmin()) * frame + frame // 2
        yield audio[start:cut]
        start = cut
    yield audio[start:]

model_dir, items_path, out_path = sys.argv[1:4]
CACHE_LIMIT_BYTES = 1 << 30  # MLX's buffer cache otherwise grows past 15 GB over a 1 h track
mx.set_cache_limit(CACHE_LIMIT_BYTES)
model = CohereAsrModel.from_path(model_dir)
out = {}
for item in json.load(open(items_path)):
    audio, rate = soundfile.read(item['path'], dtype='float32', always_2d=False)
    started = time.time()
    text = ' '.join(transcribe_window(piece, rate) for piece in windows(audio, rate)).strip()
    print(item['id'], round(len(audio) / rate), 's audio', round(time.time() - started), 's', round(mx.get_peak_memory() / 1e9, 1), 'GB peak', flush=True)
    out[item['id']] = {'text': text.strip(), 'seconds': round(time.time() - started, 2)}
out['_peak_rss_mb'] = round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1e6)  # bytes on macOS
out['_peak_mlx_mb'] = round(mx.get_peak_memory() / 1e6)
json.dump(out, open(out_path, 'w'))
