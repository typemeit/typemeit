"""Underdog Bark 3.0 Pro (Conway Research, CC-BY-4.0; English fine-tune of Parakeet TDT v3 at full
precision) as its Core ML folder, through the fluidasr CLI's `bark-pro` mode (see fluid_common and
the mode's comment in fluidasr). BARK_PRO_DIR points at the extracted `coreml/` folder of
ConwayResearch/Underdog-Bark-3.0-Pro (default build/bark-pro/coreml). The folder names its
vocabulary parakeet_v3_vocab.json; fluidasr compiles the packages and reads parakeet_vocab.json,
so a copy with that name is added (fluidasr copies it on into compiled/, where a relative link would dangle)."""
import os, shutil
from . import fluid_common

NAME = 'bark-pro'
VOCABULARY, LOADER_VOCABULARY = 'parakeet_v3_vocab.json', 'parakeet_vocab.json'

def transcribe(items):
    model_dir = os.environ.get('BARK_PRO_DIR', str(fluid_common.REPO / 'build/bark-pro/coreml'))
    if not os.path.exists(os.path.join(model_dir, LOADER_VOCABULARY)):
        shutil.copy(os.path.join(model_dir, VOCABULARY), os.path.join(model_dir, LOADER_VOCABULARY))
    os.environ['FLUIDASR_MODEL_DIR'] = model_dir
    cli = fluid_common.binary()
    return fluid_common.transcribe_by(lambda kind: [cli, 'bark-pro'], NAME, items)
