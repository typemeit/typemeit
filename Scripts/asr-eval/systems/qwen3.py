"""Qwen3-ASR-0.6B (Core ML, f32) through Scripts/asr-eval/qwen3asr, which pins FluidAudio 0.15.2, the last
tag with the backend. Every clip in 20 s windows, no VAD (the decoder cache holds 512 tokens)."""
import os, pathlib, subprocess
from . import fluid_common

NAME = 'qwen3'
VARIANT = 'f32'
PACKAGE = pathlib.Path(__file__).resolve().parents[1] / 'qwen3asr'
SCRATCH = fluid_common.REPO / 'build/asr-eval-qwen3asr'

def binary():
    base = ['swift', 'build', '-c', 'release', '--package-path', str(PACKAGE), '--scratch-path', str(SCRATCH)]
    subprocess.run(base, check=True)
    out = subprocess.run(base + ['--show-bin-path'], capture_output=True, text=True, check=True).stdout.strip()
    return os.path.join(out, 'qwen3asr')

def transcribe(items):
    cli = binary()
    return fluid_common.transcribe_by(lambda kind: [cli, VARIANT, kind], NAME, items)
