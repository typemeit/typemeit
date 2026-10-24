"""Underdog Bark 3.0 Plus (Conway Research, CC-BY-4.0; low-bit English fine-tune of Parakeet TDT v3)
through its own runner, `bark_coreml.py` from the model repo's coreml/ane/ folder: a Core ML encoder
on the Neural Engine in 8 or 15 s windows, a numpy TDT decoder, long audio cut at pauses. Not
FluidAudio's layout, so it runs in bark_plus_worker.py under build/asr-eval-venv-bark, which holds
coremltools. BARK_PLUS_DIR points at the extracted coreml/ane/ folder of
ConwayResearch/Underdog-Bark-3.0-Plus (default build/bark-plus/ane). Timings are the Python
decoder's, not what a Swift port in the app would take."""
import os, pathlib, subprocess
from . import fluid_common

NAME = 'bark-plus'
WORKER = pathlib.Path(__file__).with_name('bark_plus_worker.py')
VENV = fluid_common.REPO / 'build/asr-eval-venv-bark'
PYTHON = '/opt/homebrew/bin/python3.13'
PACKAGES = ['coremltools', 'numpy', 'soundfile']

def transcribe(items):
    python = VENV / 'bin/python'
    if not python.exists():
        subprocess.run([PYTHON, '-m', 'venv', str(VENV)], check=True)
        subprocess.run([str(VENV / 'bin/pip'), 'install', '-q', *PACKAGES], check=True)
    model_dir = os.environ.get('BARK_PLUS_DIR', str(fluid_common.REPO / 'build/bark-plus/ane'))
    return fluid_common.transcribe_by(lambda kind: [str(python), '-I', str(WORKER), model_dir], NAME, items)
