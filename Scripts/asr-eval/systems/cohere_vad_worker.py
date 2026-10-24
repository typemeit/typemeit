"""Runs inside build/asr-eval-venv. usage: cohere_vad_worker.py MODEL_DIR ITEMS_JSON OUT_JSON
Like cohere_worker.py, but only the speech found by Silero VAD is transcribed (see vad.py).
OUT_JSON is {id: {text, seconds, chunks, speech_seconds}, "_peak_rss_mb": n}."""
import json, pathlib, resource, sys, time
import mlx.core as mx
import soundfile
sys.path.insert(0, str(pathlib.Path(__file__).parent))
import vad
from mlx_speech.generation import CohereAsrModel

model_dir, items_path, out_path = sys.argv[1:4]
mx.set_cache_limit(1 << 30)
model = CohereAsrModel.from_path(model_dir)
out = {}
for item in json.load(open(items_path)):
    audio, rate = soundfile.read(item['path'], dtype='float32', always_2d=False)
    started = time.time()
    pieces = vad.chunks(audio)
    texts = []
    for piece in pieces:
        texts.append(model.transcribe(piece, sample_rate=rate, language='en').text.strip())
        mx.clear_cache()
    text = ' '.join(texts).strip()
    print(item['id'], round(len(audio) / rate), 's audio', round(time.time() - started), 's', len(pieces), 'chunks', round(mx.get_peak_memory() / 1e9, 1), 'GB peak', flush=True)
    out[item['id']] = {'text': text, 'seconds': round(time.time() - started, 2), 'chunks': len(pieces),
                       'speech_seconds': round(sum(len(p) for p in pieces) / rate, 1)}
out['_peak_rss_mb'] = round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1e6)
out['_peak_mlx_mb'] = round(mx.get_peak_memory() / 1e6)
json.dump(out, open(out_path, 'w'))
