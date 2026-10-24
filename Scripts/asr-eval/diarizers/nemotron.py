"""The shipped Nemotron 3 Diarization turns (Diarizer.turns: Nemotron3Diarizer over FluidAudio, then
SpeakerFrames.segments with Fixed.meetingTurnThreshold and Fixed.meetingTurnMinimumMs), through
Scripts/asr-eval/diar, which compiles the app's own SpeakerFrames.swift. Needs the speaker models
installed by the app (models/diarizer/nemotron-3-diarization; TYPEMEIT_NEMOTRON_DIR overrides)."""
from . import diar_common

NAME = 'nemotron'

def diarize(path):
    return diar_common.diarize_with('nemotron', NAME, path)
