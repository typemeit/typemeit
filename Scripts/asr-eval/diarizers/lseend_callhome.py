"""LS-EEND (callhome variant, FluidAudio 0.17.5, Core ML, 100 ms step) through Scripts/asr-eval/diar."""
from . import diar_common

NAME = 'lseend_callhome'

def diarize(path):
    return diar_common.diarize_with('lseend-callhome', NAME, path)
