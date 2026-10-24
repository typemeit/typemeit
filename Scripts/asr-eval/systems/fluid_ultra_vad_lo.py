"""fluid-ultra-vad with a lenient gate: Silero threshold 0.25, gaps under 1 s merged, 0.4 s padding,
chunks of at most 14.5 s. The default gate drops quiet speech; see fluid_ultra_vad."""
from . import fluid_ultra_vad

NAME = 'fluid-ultra-vad-lo'
VAD = {'THRESHOLD': 0.25, 'MERGE_GAP_S': 1.0, 'PAD_S': 0.4, 'MIN_SPEECH_S': 0.15}

def transcribe(items):
    return fluid_ultra_vad.transcribe_chunked(NAME, fluid_ultra_vad.CHUNK_SECONDS, items, VAD)
