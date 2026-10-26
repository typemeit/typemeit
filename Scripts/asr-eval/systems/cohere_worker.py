"""Runs inside build/asr-eval-venv (Python 3.13, mlx-speech). usage: cohere_worker.py MODEL_DIR ITEMS_JSON OUT_JSON
ITEMS_JSON is [{id, path}] of 16 kHz mono WAVs. OUT_JSON is {id: {text, seconds}, "_peak_rss_mb": n}."""
import json, pathlib, resource, sys, time
import mlx.core as mx
import soundfile
sys.path.insert(0, str(pathlib.Path(__file__).parent))
import vad
from mlx_speech.generation import CohereAsrModel

# The model card's max_audio_clip_s is 35 s with a 5 s overlap, so a clip up to 30 s takes the model's
# single-window path. Longer audio is cut by vad.split_long into windows of at most WINDOW_SECONDS at
# quiet points, and the texts are joined with a space.
WINDOW_SECONDS = 30.0

def transcribe_window(piece, rate):
    text = model.transcribe(piece, sample_rate=rate, language='en').text.strip()
    mx.clear_cache()
    return text

model_dir, items_path, out_path = sys.argv[1:4]
CACHE_LIMIT_BYTES = 1 << 30  # MLX's buffer cache otherwise grows past 15 GB over a 1 h track
mx.set_cache_limit(CACHE_LIMIT_BYTES)
model = CohereAsrModel.from_path(model_dir)
out = {}
for item in json.load(open(items_path)):
    audio, rate = soundfile.read(item['path'], dtype='float32', always_2d=False)
    started = time.time()
    text = ' '.join(transcribe_window(piece, rate) for piece in vad.split_long(audio, WINDOW_SECONDS, rate)).strip()
    print(item['id'], round(len(audio) / rate), 's audio', round(time.time() - started), 's', round(mx.get_peak_memory() / 1e9, 1), 'GB peak', flush=True)
    out[item['id']] = {'text': text.strip(), 'seconds': round(time.time() - started, 2)}
out['_peak_rss_mb'] = round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1e6)  # bytes on macOS
out['_peak_mlx_mb'] = round(mx.get_peak_memory() / 1e6)
json.dump(out, open(out_path, 'w'))
