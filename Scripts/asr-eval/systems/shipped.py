"""The app's own speech path (Transcriber, and the meeting chunk loop) through Scripts/asr-app-path,
so a score is what the shipped app produces."""
from . import fluid_common

NAME = 'shipped'
RUN = fluid_common.REPO / 'Scripts/asr-app-path/run.sh'

def transcribe(items):
    return fluid_common.transcribe_by(lambda kind: [str(RUN), kind], NAME, items)
