"""FluidVoice's Fluid Speech Mini (CC-BY-4.0; Parakeet TDT v3 encoder fine-tuned for dictation, Parakeet
Ultra's decoder and joint) as its Core ML package, through the fluidasr CLI's `local` mode (see
fluid_common). prepare() downloads the package's compiled models into build/ (git-ignored). FluidAudio's
v3 loader looks for the joint as JointDecisionv3.mlmodelc; the package names it JointDecision.mlmodelc,
so a link with the loader's name is added."""
import json, os, urllib.request
from . import fluid_common

NAME = 'fluid-speech-mini'
REPO_ID = 'FluidVoice-Labs/fluid-speech-mini-coreml'
REVISION = 'main'
MODEL_DIR = fluid_common.REPO / 'build/asr-eval-models/fluid-speech-mini'
SKIPPED_FOLDERS = ('assets/', 'examples/')
JOINT, LOADER_JOINT = 'JointDecision.mlmodelc', 'JointDecisionv3.mlmodelc'

def repo_files(repo_id):
    with urllib.request.urlopen(f'https://huggingface.co/api/models/{repo_id}/tree/{REVISION}?recursive=true') as listing:
        entries = json.load(listing)
    return [e['path'] for e in entries if e['type'] == 'file' and not e['path'].startswith(SKIPPED_FOLDERS)]

def prepare(repo_id, model_dir):
    if not (model_dir / JOINT).exists():
        for path in repo_files(repo_id):
            target = model_dir / path
            target.parent.mkdir(parents=True, exist_ok=True)
            urllib.request.urlretrieve(f'https://huggingface.co/{repo_id}/resolve/{REVISION}/{path}', target)
    if not (model_dir / LOADER_JOINT).exists():
        os.symlink(JOINT, model_dir / LOADER_JOINT)

def transcribe_model(repo_id, model_dir, name, items):
    """Runs a Parakeet v3-layout Core ML package from Hugging Face through `fluidasr local`."""
    prepare(repo_id, model_dir)
    os.environ['FLUIDASR_MODEL_DIR'] = str(model_dir)
    cli = fluid_common.binary()
    return fluid_common.transcribe_by(lambda kind: [cli, 'local'], name, items)

def transcribe(items):
    return transcribe_model(REPO_ID, MODEL_DIR, NAME, items)
