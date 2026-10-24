"""LS-EEND (FluidAudio 0.17.5, Core ML, 100 ms step, AMI variant) through Scripts/asr-eval/diar."""
from . import diar_common

NAME = 'lseend'

def diarize(path):
    return diar_common.diarize_with('lseend-ami', NAME, path)
