"""Silero VAD (onnx, 16 kHz) for the cohere-vad system. Runs inside build/asr-eval-venv
(onnxruntime, numpy). speech_regions(audio) -> [(start_s, end_s)] of raw speech;
chunks(audio) -> audio pieces of at most MAX_CHUNK_SECONDS holding only speech regions.
split_long needs only numpy, so onnxruntime is imported where Silero runs and granite-nar can
cut at quiet points outside the venv."""
import pathlib
import numpy as np

RATE = 16000
MODEL = pathlib.Path(__file__).resolve().parents[3] / 'build/asr-eval-models/silero/silero_vad/data/silero_vad.onnx'
FRAME = 512
CONTEXT = 64
THRESHOLD = 0.5
MIN_SPEECH_S = 0.25
MERGE_GAP_S = 0.5
PAD_S = 0.2
MAX_CHUNK_SECONDS = 30.0
SEARCH_SECONDS = 5.0
FRAME_SECONDS = 0.05

def probabilities(audio):
    import onnxruntime
    session = onnxruntime.InferenceSession(str(MODEL), providers=['CPUExecutionProvider'])
    state = np.zeros((2, 1, 128), dtype=np.float32)
    context = np.zeros((1, CONTEXT), dtype=np.float32)
    rate = np.array(RATE, dtype=np.int64)
    out = []
    for start in range(0, len(audio), FRAME):
        frame = audio[start:start + FRAME]
        if len(frame) < FRAME:
            frame = np.pad(frame, (0, FRAME - len(frame)))
        x = np.concatenate([context, frame[None, :].astype(np.float32)], axis=1)
        prob, state = session.run(None, {'input': x, 'state': state, 'sr': rate})
        context = x[:, -CONTEXT:]
        out.append(float(prob[0][0]))
    return np.array(out)

def speech_regions(audio):
    speaking = probabilities(audio) >= THRESHOLD
    regions, begin = [], None
    for n, flag in enumerate(speaking):
        if flag and begin is None:
            begin = n
        if not flag and begin is not None:
            regions.append((begin * FRAME / RATE, n * FRAME / RATE))
            begin = None
    if begin is not None:
        regions.append((begin * FRAME / RATE, len(speaking) * FRAME / RATE))
    return [r for r in regions if r[1] - r[0] >= MIN_SPEECH_S]

def padded_regions(regions, total_seconds):
    merged = []
    for begin, end in regions:
        if merged and begin - merged[-1][1] < MERGE_GAP_S:
            merged[-1] = (merged[-1][0], end)
        else:
            merged.append((begin, end))
    return [(max(0.0, b - PAD_S), min(total_seconds, e + PAD_S)) for b, e in merged]

def split_long(piece, max_seconds, rate, search_seconds=SEARCH_SECONDS):
    """Cuts piece into windows of at most max_seconds, each ending mid-way through the quietest
    FRAME_SECONDS frame in its last search_seconds. Nothing is dropped."""
    window, search, frame = int(max_seconds * rate), int(search_seconds * rate), int(FRAME_SECONDS * rate)
    start = 0
    while len(piece) - start > window:
        tail = piece[start + window - search:start + window]
        frames = len(tail) // frame
        energy = (tail[:frames * frame].reshape(frames, frame) ** 2).mean(axis=1)
        cut = start + window - search + int(energy.argmin()) * frame + frame // 2
        yield piece[start:cut]
        start = cut
    yield piece[start:]

def chunks(audio):
    pieces = [audio[int(b * RATE):int(e * RATE)] for b, e in padded_regions(speech_regions(audio), len(audio) / RATE)]
    pieces = [part for piece in pieces for part in split_long(piece, MAX_CHUNK_SECONDS, RATE)]
    packed, current, length = [], [], 0
    for piece in pieces:
        if current and length + len(piece) > MAX_CHUNK_SECONDS * RATE:
            packed.append(np.concatenate(current))
            current, length = [], 0
        current.append(piece)
        length += len(piece)
    if current:
        packed.append(np.concatenate(current))
    return packed
