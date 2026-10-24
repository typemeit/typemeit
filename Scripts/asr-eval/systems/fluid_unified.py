"""Parakeet Unified (Core ML int8, FluidInference/parakeet-unified-en-0.6b-coreml) through UnifiedAsrManager,
which cuts long audio into overlapping 15 s windows itself; see fluid_common."""
from . import fluid_common

NAME = 'fluid-unified'

def transcribe(items):
    return fluid_common.transcribe_with('unified', NAME, items)
