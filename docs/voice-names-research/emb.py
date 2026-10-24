"""The app's WeSpeaker model, called the way FluidAudio's embedSpan calls it.

EMBED=tile (the default) repeats the clip to fill the window and weights every frame, as embedSpan
does from FluidAudio 0.17.6 and Diarizer.voice(of:) does to match. EMBED=pad zero-pads it and
weights only the frames it covers, as both did before."""
import numpy as np, coremltools as ct, os, subprocess
M = os.path.expanduser('~/Library/Application Support/TypeMeIt/models/diarizer/speaker-diarization')
RATE, WIN, FRAMES = 16000, 160000, 589
MODE = os.environ.get('EMBED', 'tile')
fbank = ct.models.CompiledMLModel(f'{M}/FBank.mlmodelc')
embed = ct.models.CompiledMLModel(f'{M}/Embedding.mlmodelc')

def decode(path):
    raw = subprocess.run(['ffmpeg', '-v', 'error', '-i', path, '-ac', '1', '-ar', str(RATE), '-f', 'f32le', '-'], capture_output=True, check=True).stdout
    return np.frombuffer(raw, dtype=np.float32)

def embedding(clip):
    n = min(len(clip), WIN)
    audio = np.zeros((1, 1, WIN), dtype=np.float32)
    if MODE == 'tile':
        audio[0, 0, :] = np.resize(clip[:n], WIN)
        w = np.ones((1, FRAMES), dtype=np.float32)
    else:
        audio[0, 0, :n] = clip[:n]
        w = np.zeros((1, FRAMES), dtype=np.float32); w[0, :max(1, min(FRAMES, round(n / WIN * FRAMES)))] = 1
    fb = fbank.predict({'audio': audio})['fbank_features']
    return np.asarray(embed.predict({'fbank_features': fb, 'weights': w})['embedding'], dtype=np.float32).reshape(-1)
