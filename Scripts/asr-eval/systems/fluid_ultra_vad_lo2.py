"""fluid-ultra-vad with a lenient gate: Silero threshold 0.1, gaps under 2 s merged, 0.5 s padding,
chunks of at most 14.5 s. The default gate drops quiet speech; see fluid_ultra_vad."""
from . import fluid_ultra_vad

NAME = 'fluid-ultra-vad-lo2'
VAD = {'THRESHOLD': 0.1, 'MERGE_GAP_S': 2.0, 'PAD_S': 0.5, 'MIN_SPEECH_S': 0.1}

def transcribe(items):
    return fluid_ultra_vad.transcribe_chunked(NAME, fluid_ultra_vad.CHUNK_SECONDS, items, VAD)
