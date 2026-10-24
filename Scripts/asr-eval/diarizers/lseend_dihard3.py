"""LS-EEND (dihard3 variant, FluidAudio 0.17.5, Core ML, 100 ms step) through Scripts/asr-eval/diar."""
from . import diar_common

NAME = 'lseend_dihard3'

def diarize(path):
    return diar_common.diarize_with('lseend-dihard3', NAME, path)
