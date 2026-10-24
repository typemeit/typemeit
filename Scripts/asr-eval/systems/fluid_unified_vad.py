"""fluid-unified fed Silero speech chunks (lenient gate of fluid-ultra-vad-lo2) instead of whole tracks."""
from . import fluid_ultra_vad

NAME = 'fluid-unified-vad'

def transcribe(items):
    return fluid_ultra_vad.transcribe_chunked(NAME, fluid_ultra_vad.CHUNK_SECONDS, items, fluid_ultra_vad_lo2_vad(), 'unified')

def fluid_ultra_vad_lo2_vad():
    from . import fluid_ultra_vad_lo2
    return fluid_ultra_vad_lo2.VAD
