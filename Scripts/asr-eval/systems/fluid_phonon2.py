"""FluidAudio phonon2 (Core ML, Neural Engine) through the fluidasr CLI; see fluid_common."""
from . import fluid_common

NAME = 'fluid-phonon2'

def transcribe(items):
    return fluid_common.transcribe_with('phonon2', NAME, items)
