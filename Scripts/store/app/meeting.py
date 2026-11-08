#!/usr/bin/env python3
"""Capture the website's meeting page shot, web/shots/meeting.webp, from a
made-up meeting in a throwaway store.

    python3 Scripts/store/app/meeting.py

Builds nothing: run the Debug build first (see CLAUDE.md), with no other dev
instance running. Writes the meeting under Scripts/store/app/store/Meetings
with a silent recording so the player shows, launches the dev app on that
store with TYPEMEIT_SUPPORT_DIR, opens the meeting from the meetings tab and
saves the window without its shadow at the size the page gives it. Keep the mouse and
keyboard off while it runs. Deterministic: the same meeting every run.
"""
import json
import os
import random
import subprocess
import sys
import time
import uuid
import wave

from PIL import Image

from capture import APP, HERE, ROOT, WINDOW_ID, clone_model, osascript, sidebar_buttons

STORE = os.path.join(HERE, "store")
OUT = os.path.join(ROOT, "web", "shots", "meeting.webp")
SIZE = (2000, 1254)  # web/index.html's <img width> and height
SIDEBAR = ["insights", "dictations", "meetings", "dictionary", "settings"]
# Where the newest meeting's row sits in the meetings tab, in points from the
# window's corner, with the window at {0, 33}.
FIRST_ROW = (600, 240)

ID = "5EED0000-0000-4000-8000-000000000001"
STARTED = "2026-10-09T09:02:00Z"  # 10:02 in London
DURATION_MS = 32 * 60_000 + 12_000
SAMPLE_RATE = 16_000
FOLDER = "2026-10-09 1002 32m Launch date and pricing"
SUMMARY = ("The launch moves from the 8th to the 15th so the new pricing can be tested first. "
           "Sam sends the revised numbers on Friday and Priya tells the store team.")
SPEAKERS = [("you", "You"), ("sam", "Sam Rivera"), ("priya", "Priya Shah")]

# What the shot shows: (speaker, start in seconds, text).
OPENING = [
    ("sam", 4, "Morning. Can everyone hear me? I'm on the train, so shout if I drop."),
    ("you", 11, "We can hear you. Shall we start with the date, since everything else hangs off it?"),
    ("sam", 19, "Yes. The plan says the 8th, but if we launch on the 8th we skip the pricing test completely."),
    ("priya", 31, "And the store listing needs a week on its own. Review took six days last time."),
    ("you", 42, "Then let's move it a week. Does the 15th work for everyone?"),
    ("priya", 49, "Works for me. I'll tell the store team today so they can plan the screenshots."),
    ("sam", 57, "Fine by me. That gives us five days with the new prices before anything goes out."),
    ("you", 68, "Good. What are we testing exactly, the monthly price or the lifetime one?"),
    ("sam", 76, "Both. Half the visitors see 2.99 a month, half see 19 once, and we compare after a week."),
    ("priya", 89, "Do we have enough traffic for a week to tell us anything?"),
    ("sam", 96, "Probably not a precise answer, but enough to see if one of them falls over."),
]
# The rest of the call, below the fold: lines drawn from these, so the
# fingerprint has a whole meeting to show.
LATER = {
    "you": ["What would make us call it early?", "Let's write that down so we don't argue about it later.",
            "I can take the onboarding copy if someone checks the numbers.", "So the 15th, and the test starts Monday."],
    "sam": ["If the monthly one converts at half the rate, we stop.", "I'll pull last month's numbers tonight.",
            "The refund rate matters more than the first week's sales.", "I'll send the revised sheet on Friday."],
    "priya": ["The store team wants the final price by Wednesday.", "I'll ask whether the listing can change mid-review.",
              "Screenshots need the new price on them too.", "I'll tell them the 15th this afternoon."],
}
# Share of the talking after the opening, as the rail shows it.
WEIGHTS = {"sam": 43, "you": 31, "priya": 27}
ASIDES = ["Yeah.", "Exactly.", "Mm, fair."]


def paragraphs():
    rng = random.Random(9)
    out = []
    for i, (speaker, start, text) in enumerate(OPENING):
        end = OPENING[i + 1][1] - 1 if i + 1 < len(OPENING) else start + 7
        out.append({"speaker": speaker, "startMs": start * 1000, "endMs": end * 1000, "text": text})
    at = out[-1]["endMs"] + 2_000
    last = out[-1]["speaker"]
    while at < DURATION_MS - 20_000:
        speaker = rng.choices(list(WEIGHTS), weights=list(WEIGHTS.values()))[0]
        if speaker == last:
            continue
        end = min(at + rng.randint(5_000, 50_000), DURATION_MS - 5_000)
        out.append({"speaker": speaker, "startMs": at, "endMs": end, "text": rng.choice(LATER[speaker])})
        if end - at > 20_000 and rng.random() < 0.3:
            by = rng.choice([s for s in WEIGHTS if s != speaker])
            mid = at + (end - at) // 2
            out.append({"speaker": by, "startMs": mid, "endMs": mid + 900, "text": rng.choice(ASIDES), "aside": True})
        last = speaker
        at = end + rng.randint(0, 4_000)
    return sorted(out, key=lambda p: p["startMs"])


def silent_track(folder, role):
    """A silent recording in the kept AAC format, so the page has a player."""
    raw = os.path.join(folder, f"{role}.wav")
    with wave.open(raw, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(b"\0\0" * (DURATION_MS * SAMPLE_RATE // 1000))
    subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", raw, os.path.join(folder, f"{role}.m4a")], check=True)
    os.remove(raw)


def seed():
    folder = os.path.join(STORE, "Meetings", FOLDER)
    os.makedirs(folder, exist_ok=True)
    paras = paragraphs()
    talk = {s: sum(p["endMs"] - p["startMs"] for p in paras if p["speaker"] == s) for s, _ in SPEAKERS}
    frames = DURATION_MS * SAMPLE_RATE // 1000
    meeting = {
        "schema": 1, "id": ID, "kind": "call", "started": STARTED, "timeZone": "Europe/London",
        "ended": "2026-10-09T09:34:12Z", "durationMs": DURATION_MS, "recordedMs": DURATION_MS,
        "app": {"bundleId": "com.google.Chrome", "name": "Google Chrome"},
        "title": "Launch date and pricing", "titleSource": "generated", "published": True,
        "tracks": [{"role": "mic", "file": "mic.m4a", "frames": frames, "gaps": []},
                   {"role": "others", "file": "others.m4a", "frames": frames, "gaps": []}],
        "echo": "clean", "bothSilentMs": 0, "dictations": [],
        "speakers": [{"id": s, "name": name, "isYou": s == "you", "talkMs": talk[s],
                      **({} if s == "you" else {"nameSource": "roster"})} for s, name in SPEAKERS],
        "transcription": {"state": "done", "asr": "parakeet-ultra-95eaa59a",
                          "diarizer": "nemotron-3-diarization+wespeaker df2625ac-25a90f97",
                          "tookMs": 97_000, "asrMs": 69_000, "speakersMs": 18_000, "summaryMs": 4_000,
                          "done": {"mic": 4, "others": 4}},
        "paragraphs": paras, "summary": SUMMARY,
    }
    with open(os.path.join(folder, "meeting.json"), "w") as f:
        json.dump(meeting, f, indent=2)
    for role in ("mic", "others"):
        if not os.path.exists(os.path.join(folder, f"{role}.m4a")):
            silent_track(folder, role)


def main():
    subprocess.run([sys.executable, os.path.join(HERE, "seed.py")], check=True)
    seed()
    clone_model()
    env = dict(os.environ, TYPEMEIT_SUPPORT_DIR=STORE)
    app = subprocess.Popen([APP], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        time.sleep(6)
        subprocess.run(["open", APP.split("/Contents/MacOS/")[0]], check=True)
        time.sleep(2)
        osascript(app.pid, 'set position of window "settings" to {0, 33}')
        osascript(app.pid, 'set size of window "settings" to {1512, 949}')
        wid = subprocess.run(["swift", "-e", WINDOW_ID, str(app.pid)], capture_output=True, text=True, check=True).stdout.split()[0]
        osascript(app.pid, f'click button {sidebar_buttons(app.pid)[SIDEBAR.index("meetings")]} of group 1 of window "settings"')
        time.sleep(1.5)
        osascript(app.pid, "set frontmost to true")
        subprocess.run(["cliclick", f"c:{FIRST_ROW[0]},{FIRST_ROW[1] + 33}", "m:1500,900"], check=True)
        time.sleep(2)
        osascript(app.pid, "set frontmost to true")
        time.sleep(0.5)
        png = os.path.join(HERE, "meeting.png")
        subprocess.run(["screencapture", "-l", wid, "-o", "-x", png], check=True)
        shot = Image.open(png)
        shot.resize(SIZE, Image.LANCZOS).save(OUT, "WEBP", quality=90)
        os.remove(png)
        print(OUT)
    finally:
        app.terminate()
        app.wait()


if __name__ == "__main__":
    main()
