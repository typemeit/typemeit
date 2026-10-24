"""cohere with a Silero VAD gate: only speech regions (gaps under 0.5 s merged, 0.2 s padding),
packed into chunks of at most 30 s, go to the model. See vad.py and cohere_vad_worker.py.
Needs onnxruntime in build/asr-eval-venv and the Silero model under build/asr-eval-models/silero."""
import subprocess, sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import cohere

NAME = 'cohere-vad'

def prepare():
    python = cohere.prepare()
    subprocess.run([python, '-m', 'pip', 'install', '-q', 'onnxruntime'], check=True)
    if not (cohere.MODELS / 'silero/silero_vad/data/silero_vad.onnx').exists():
        raise SystemExit('Silero VAD model missing: pip download --no-deps silero-vad into build/asr-eval-models/silero and unzip silero_vad/data')
    return python

def transcribe(items):
    prepare()
    timed = cohere.transcribe_timed(items, worker='cohere_vad_worker.py')
    return {i['id']: timed[i['id']]['text'] for i in items}
