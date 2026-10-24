"""Runs inside build/asr-eval-venv. usage: fluid_vad_chunks.py MAX_SECONDS ITEMS_JSON OUT_DIR MANIFEST_JSON [VAD_OVERRIDES_JSON]
Cuts each 16 kHz mono wav into the Silero speech chunks of vad.py, each at most MAX_SECONDS, writes them
as wavs under OUT_DIR and a manifest {id: {"paths": [...], "vadSeconds": n}}."""
import json, pathlib, sys, time
import numpy as np
import soundfile
sys.path.insert(0, str(pathlib.Path(__file__).parent))
import vad

max_seconds, items_path, out_dir, manifest_path = sys.argv[1:5]
vad.MAX_CHUNK_SECONDS = float(max_seconds)
for key, value in json.loads(sys.argv[5] if len(sys.argv) > 5 else '{}').items():
    setattr(vad, key, value)
pathlib.Path(out_dir).mkdir(parents=True, exist_ok=True)
manifest = {}
for item in json.load(open(items_path)):
    audio, rate = soundfile.read(item['path'], dtype='float32')
    started = time.time()
    pieces = vad.chunks(audio)
    paths = []
    for n, piece in enumerate(pieces):
        piece = np.pad(piece, (0, max(0, rate - len(piece))))
        path = f"{out_dir}/{item['id']}~{n:04d}.wav"
        soundfile.write(path, piece, rate, subtype='PCM_16')
        paths.append(path)
    manifest[item['id']] = {'paths': paths, 'vadSeconds': round(time.time() - started, 2), 'audioSeconds': len(audio) / rate}
json.dump(manifest, open(manifest_path, 'w'))
