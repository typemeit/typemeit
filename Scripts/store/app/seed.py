#!/usr/bin/env python3
"""Write a made-up history.json for a throwaway store, so the dev app launched
with TYPEMEIT_SUPPORT_DIR pointing there shows it in its Insights tab.

    python3 Scripts/store/app/seed.py
    TYPEMEIT_SUPPORT_DIR=Scripts/store/app/store "build/dd/Build/Products/Debug/type me it dev.app/Contents/MacOS/type me it dev"

The dev app otherwise reads the real history in ~/Library, which this never
touches. Deterministic: the same numbers come out every
run, so the capture can be retaken.
"""
import json
import os
import random
import uuid
from datetime import datetime, timedelta, timezone

SUPPORT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "store")
DAYS = 130
SPOKEN_WPM = 125  # how fast the transcripts were dictated; the tab reports this against typing at 40

# (weight, appId, appName, windowTitle)
APPS = [
    (26, "com.anthropic.claudefordesktop", "Claude", None),
    (18, "com.tinyspeck.slackmacgap", "Slack", None),
    (12, "com.apple.MobileSMS", "Messages", None),
    (9, "com.apple.mail", "Mail", None),
    (8, "com.apple.Notes", "Notes", None),
    (8, "com.todesktop.230313mzl4w4u92", "Cursor", None),
    (6, "com.mitchellh.ghostty", "Ghostty", "Claude Code — typemeit"),
    (5, "com.google.Chrome", "Google Chrome", "Inbox (3) - max@example.com - Gmail"),
    (4, "com.google.Chrome", "Google Chrome", "Pull requests · typemeit — GitHub"),
    (4, "com.google.Chrome", "Google Chrome", "Porto in October — Google Search"),
]

# The newest dictations are what the History capture shows, so they are
# written by hand: what was heard, with the fillers, and what was typed once
# Apple Intelligence had tidied it. Oldest first; the last few are today's.
# (heard, typed, appName, appId)
RECENT = [
    ("um so the deck is in the shared folder now I moved the pricing slide to the end so it lands after the demo can you take another look before the call",
     "The deck is in the shared folder now. I moved the pricing slide to the end so it lands after the demo. Can you take another look before the call?",
     "Slack", "com.tinyspeck.slackmacgap"),
    ("hey are we still on for thursday I can do any time after two",
     "Hey, are we still on for Thursday? I can do any time after two.",
     "Messages", "com.apple.MobileSMS"),
    ("write a function that takes a list of dates and returns the longest run of consecutive days um it should ignore duplicates",
     "Write a function that takes a list of dates and returns the longest run of consecutive days. It should ignore duplicates.",
     "Claude", "com.anthropic.claudefordesktop"),
    ("thanks for sending this over I've had a read and I think the second option is the one to go with mainly because it's the least work for the team happy to talk it through tomorrow if that helps",
     "Thanks for sending this over. I've had a read and I think the second option is the one to go with, mainly because it's the least work for the team. Happy to talk it through tomorrow if that helps.",
     "Mail", "com.apple.mail"),
    ("porto ideas so the ribeira for the first night then the day trip to the douro on the saturday and um leave sunday free",
     "Porto ideas: the Ribeira for the first night, then the day trip to the Douro on the Saturday, and leave Sunday free.",
     "Notes", "com.apple.Notes"),
    ("can you move the retro to four I've got a dentist thing at three",
     "Can you move the retro to four? I've got a dentist thing at three.",
     "Slack", "com.tinyspeck.slackmacgap"),
    ("so the failing test is the one that checks the streak um it breaks when there's a gap of exactly one day I think the off by one is in the date comparison",
     "The failing test is the one that checks the streak. It breaks when there's a gap of exactly one day. I think the off-by-one is in the date comparison.",
     "Claude", "com.anthropic.claudefordesktop"),
    ("dinner at ours on friday bring nothing we've got too much wine already",
     "Dinner at ours on Friday. Bring nothing, we've got too much wine already.",
     "Messages", "com.apple.MobileSMS"),
    ("ok rename the branch to store screenshots and um squash the last two commits before you push",
     "Rename the branch to store screenshots and squash the last two commits before you push.",
     "Ghostty", "com.mitchellh.ghostty"),
    ("quick one before I forget the invoice for august is still showing as unpaid on our side can you check whether it went out",
     "Quick one before I forget: the invoice for August is still showing as unpaid on our side. Can you check whether it went out?",
     "Mail", "com.apple.mail"),
    ("things to ask the landlord um the boiler service the broken latch on the back gate and whether the lease can go to eighteen months",
     "Things to ask the landlord: the boiler service, the broken latch on the back gate, and whether the lease can go to eighteen months.",
     "Notes", "com.apple.Notes"),
    ("draft a short reply saying thanks we'll come back to them next week once the numbers are in",
     "Draft a short reply saying thanks, we'll come back to them next week once the numbers are in.",
     "Claude", "com.anthropic.claudefordesktop"),
    ("running about ten minutes late um order me whatever you're having",
     "Running about ten minutes late. Order me whatever you're having.",
     "Messages", "com.apple.MobileSMS"),
    ("the demo went fine the only question was about export so I said it's on the list for next quarter which I think is still true",
     "The demo went fine. The only question was about export, so I said it's on the list for next quarter, which I think is still true.",
     "Slack", "com.tinyspeck.slackmacgap"),
]

WORDS = ("the deck is in the shared folder and I moved the pricing slide to the end so it lands after the demo "
         "can you take another look before the call and tell me if the numbers still make sense to you").split()


def sentence(rng, n):
    return " ".join(rng.choice(WORDS) for _ in range(n)).capitalize() + "."


def main():
    rng = random.Random(7)
    now = datetime.now(timezone.utc)
    today = now.replace(hour=0, minute=0, second=0, microsecond=0)
    entries = []
    for back in range(DAYS - 1, -1, -1):
        day = today - timedelta(days=back)
        weekend = day.weekday() >= 5
        # Usage grows over the period and steps up in the last month so the
        # month-on-month figure is positive, with quiet weekends and a few
        # days off, though never in the last three weeks so the streak runs.
        ramp = (0.4 + 0.6 * (DAYS - back) / DAYS) * (1 if back < 30 else 0.45)
        if back > 21 and rng.random() < (0.55 if weekend else 0.08):
            continue
        count = max(1, int(rng.gauss(4 if weekend else 14, 4) * ramp))
        handwritten = RECENT[:6] if back == 1 else RECENT[6:] if back == 0 else []
        for i in range(len(handwritten) or count):
            weights = [a[0] for a in APPS]
            _, app_id, app_name, title = rng.choices(APPS, weights)[0]
            words = max(4, int(rng.lognormvariate(3.3, 0.6)))
            duration = int(words / SPOKEN_WPM * 60_000 * rng.uniform(0.85, 1.2))
            cleaned = rng.random() < 0.7
            # Today's dictations stop at the current hour so none is in the future.
            latest = min(21, max(9, now.hour)) if back == 0 else 21
            at = day + timedelta(hours=rng.uniform(8, latest))
            entry = dict(
                id=str(uuid.UUID(int=rng.getrandbits(128))).upper(),
                timestamp=at.strftime("%Y-%m-%dT%H:%M:%SZ"),
                starred=False,
                transcript=sentence(rng, words),
                postProcessRequested=cleaned,
                durationMs=duration,
                transcribeMs=int(duration * rng.uniform(0.03, 0.05)),
                appId=app_id,
                appName=app_name,
                dictionaryFixes=1 if rng.random() < 0.12 else 0,
            )
            if cleaned:
                # Clean-ups count only when Apple Intelligence changed a word;
                # punctuation alone does not count.
                changed = rng.random() < 0.6
                entry["postProcessed"] = entry["transcript"].replace(" the ", " that ", 1) if changed else entry["transcript"]
                entry["postProcessMs"] = int(rng.gauss(1900, 400))
            if i < len(handwritten):
                heard, typed, app_name, app_id = handwritten[i]
                entry.update(transcript=heard, postProcessed=typed, postProcessRequested=True, appName=app_name, appId=app_id,
                             postProcessMs=int(rng.gauss(1900, 400)), recordingFile=entry["id"] + ".wav")
                entry.pop("windowTitle", None)
            if title:
                entry["windowTitle"] = title
            entries.append(entry)
    entries.sort(key=lambda e: e["timestamp"])

    os.makedirs(SUPPORT, exist_ok=True)
    path = os.path.join(SUPPORT, "history.json")
    with open(path, "w") as f:
        json.dump(entries, f, indent=1, sort_keys=True)
    print(f"{len(entries)} dictations, {sum(len(e['transcript'].split()) for e in entries)} words -> {path}")


if __name__ == "__main__":
    main()
