"""fluid-ultra-vad with chunks of at most 10 s; see fluid_ultra_vad."""
from . import fluid_ultra_vad

NAME = 'fluid-ultra-vad10'
CHUNK_SECONDS = 10.0

def transcribe(items):
    return fluid_ultra_vad.transcribe_chunked(NAME, CHUNK_SECONDS, items)
