"""nemotron_app plus the cap a call's meeting window sets: SpeakerCount reads the meeting.json
beside the track (the stored paragraphs stand in for the words), and SpeakerMerge.capped folds
the quietest voices into the nearest until the cap is met, as Diarizer.run does. Scores a change
to how many voices the window lets a call keep."""
import pathlib
from . import diar_common

NAME = 'nemotron_app_window'

def diarize(path):
    meeting = pathlib.Path(path).resolve().parent / 'meeting.json'
    return diar_common.diarize_with('nemotron-app-window', NAME, path, extra=[str(meeting)])
