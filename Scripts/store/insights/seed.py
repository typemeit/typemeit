#!/usr/bin/env python3
"""Write a made-up history.json for a throwaway store, so the dev app launched
with TYPEMEIT_SUPPORT_DIR pointing there shows it in its Insights tab.

    python3 Scripts/store/insights/seed.py
    TYPEMEIT_SUPPORT_DIR=Scripts/store/insights/store "build/dd/Build/Products/Debug/type me it dev.app/Contents/MacOS/type me it dev"

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
        for _ in range(count):
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
