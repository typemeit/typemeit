"""FluidVoice's Fluid Speech Pro (CC-BY-4.0; Parakeet TDT v3 fine-tune with one extra encoder block,
int8 encoder, fp16 decoder and joint; detects its language itself, with no setting to fix one) as its
Core ML package, through the fluidasr CLI's `local` mode, the same Parakeet v3 layout as Fluid Speech
Mini (see fluid_speech_mini)."""
from . import fluid_speech_mini, fluid_common

NAME = 'fluid-speech-pro'
REPO_ID = 'FluidVoice-Labs/fluid-speech-pro-coreml'
MODEL_DIR = fluid_common.REPO / 'build/asr-eval-models/fluid-speech-pro'

def transcribe(items):
    return fluid_speech_mini.transcribe_model(REPO_ID, MODEL_DIR, NAME, items)
