"""CohereLabs/cohere-transcribe-03-2026 (2B, Apache-2.0) as the MLX int8 conversion
mlx-community/cohere-transcribe-03-2026-mlx-8bit, run by mlx-speech in build/asr-eval-venv.
That package needs Python >= 3.13, so the model runs in a subprocess (cohere_worker.py) and the
venv and the downloaded weights both live under build/ (git-ignored). prepare() builds the venv
and downloads the weights on first use. English only; long audio is cut into windows of at most 30 s
at quiet points by the worker."""
import json, os, pathlib, subprocess, sys, tempfile
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
import store
from systems import fluid_common

NAME = 'cohere'
WORKER = 'cohere_worker.py'
REPO = pathlib.Path(__file__).resolve().parents[3]
VENV = REPO / 'build/asr-eval-venv'
MODELS = REPO / 'build/asr-eval-models'
HF_REPO = 'mlx-community/cohere-transcribe-03-2026-mlx-8bit'
WEIGHTS = 'mlx-int8'
PYTHON = '/opt/homebrew/bin/python3.13'
PACKAGES = ['git+https://github.com/appautomaton/mlx-speech', 'soundfile', 'huggingface_hub']

def prepare():
    python = VENV / 'bin/python'
    if not python.exists():
        subprocess.run([PYTHON, '-m', 'venv', str(VENV)], check=True)
        subprocess.run([str(VENV / 'bin/pip'), 'install', '-q', *PACKAGES], check=True)
    if not (MODELS / WEIGHTS / 'model.safetensors').exists():
        subprocess.run([str(VENV / 'bin/python'), '-c',
                        f'from huggingface_hub import snapshot_download; snapshot_download("{HF_REPO}", local_dir="{MODELS}")'],
                       check=True)
    return str(python)

def transcribe_timed(items, worker=WORKER):
    """{id: {text, seconds}} plus '_peak_rss_mb' for the whole worker process."""
    python = prepare()
    converted = [{'id': i['id'], 'path': fluid_common.wav(i['path'], i['id'])} for i in items]
    with tempfile.TemporaryDirectory() as tmp:
        listing, out = os.path.join(tmp, 'items.json'), os.path.join(tmp, 'out.json')
        json.dump(converted, open(listing, 'w'))
        subprocess.run([python, str(pathlib.Path(__file__).with_name(worker)), str(MODELS / WEIGHTS), listing, out],
                       check=True)
        return json.load(open(out))

def transcribe(items):
    timed = transcribe_timed(items)
    return {clip_id: timed[clip_id]['text'] for clip_id in (i['id'] for i in items)}
