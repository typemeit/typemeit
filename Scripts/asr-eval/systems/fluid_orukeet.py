"""Orukeet r3 (Parakeet TDT v3 fine-tune, Core ML greedy bundle) through the fluidasr CLI's `local` mode;
see fluid_common. ORUKEET_DIR points at the extracted bundle (orukeet-r3-coreml-greedy/), see the README."""
import os
from . import fluid_common

NAME = 'fluid-orukeet'

def transcribe(items):
    os.environ['FLUIDASR_MODEL_DIR'] = os.environ['ORUKEET_DIR']
    cli = fluid_common.binary()
    return fluid_common.transcribe_by(lambda kind: [cli, 'local'], NAME, items)
