"""The shipped Nemotron turns plus the app's next step on a track with no window count: one
WeSpeaker embedding per speaker (FluidAudio's offline pipeline over the speaker's longest 30 s) and
SpeakerMerge.absorbingShort, which folds speakers with under 10 s of talk into the nearest voice.
Scores what a FluidAudio embedding change does to the transcript. FLUIDAUDIO_VERSION picks the tag."""
from . import diar_common

NAME = 'nemotron_app'

def diarize(path):
    return diar_common.diarize_with('nemotron-app', NAME, path)
