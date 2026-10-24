"""FluidAudio ultra (Core ML, Neural Engine) through the fluidasr CLI; see fluid_common."""
from . import fluid_common

NAME = 'fluid-ultra'

def transcribe(items):
    return fluid_common.transcribe_with('ultra', NAME, items)
