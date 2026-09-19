# Meetings

A plan, not a spec. Dictation stays what it is; this adds a second thing the
app does — record a meeting, transcribe it, keep it somewhere useful — and a
smaller change to dictation itself along the way.

Nothing here is built except phase 1's first half (`d18b464` on
`claude/parakeet-audio-macos-stream-gizr90`, unbuilt and unverified: no Swift
toolchain in the environment it was written in).

## What we are building

1. **Streaming dictation while another app has the mic.** The encoder work
   spreads across the recording instead of bursting on key-up, which matters
   when a call is encoding video at the same time.
2. **Meeting recording, with consent.** Something else takes the mic, we ask
   once, and record both sides.
3. **Speakers.** Who said what, named where the meeting app will tell us.

Each phase is useful alone. Phase 2 is where the permission and storage
questions land, and it is blocked on the one open question at the bottom.

## Constraints that shaped this

From `transcribe.cpp` v0.2.3, which the app already pins:

- **One active stream per model, across every session of it.** A stated 0.x
  limitation — overlapping compute corrupts decodes. Two concurrent Parakeet
  streams need the model loaded twice, and the loader does not mmap, so that
  is a real second 731 MB.
- A second, *different* model streams alongside the first without conflict.
- `parakeet-unified-en-0.6b`, the model the app ships, is the one Parakeet
  variant with buffered streaming, from the same weights. No second download
  for phase 1.
- `multitalker-parakeet-streaming-0.6b-v1` gives speaker-attributed ASR from
  one 873 MB file, but **diarization is offline-API only** — `stream_feed`
  exposes single-speaker text. Fine for a run at the end; useless live.
- `MOSS-Transcribe-Diarize` is out: not streaming, and memory grows ~85 MB per
  minute of audio (~5 GB for an hour).

## Detection

**The gate is dumb on purpose.** Any process other than ours running mic
input. One CoreAudio boolean, no meeting-app list, no browser handling, no
window-title parsing. Google Meet works because we stopped asking what the app
is.

This is also what Wispr Flow's own docs describe: detecting which app is using
the microphone is fully supported on macOS 14.2+, and the app allow-list is
the legacy fallback that "doesn't cover browsers."

**Resolution, not classification.** For each process object with
`kAudioProcessPropertyIsRunningInput`:

1. `kAudioProcessPropertyPID`, skipping our own `getpid()` — which also keeps
   the dev build honest in a way bundle-ID exclusion would not.
2. `proc_pidpath` → the **outermost** `.app` in the path → its bundle
   identifier. `/Applications/Google Chrome.app/…/Google Chrome Helper
   (Audio).app/…` resolves to `com.google.Chrome`.

This step is not optional. Browsers and Electron apps do audio in helper
processes, so an exact bundle-ID match against the audio process would miss
Teams and Slack as surely as it misses Meet.

The resolved identity is used for exactly two mechanical things: naming the
app in the prompt, and knowing which process to tap. It decides nothing.

**When several apps hold the mic, take the one that is also running output.**
A call has both directions; a mic filter does not. That removes the
Krisp/Loopback false positive without a list to maintain.

### The state machine

Starting values from `atrium-pa-mac`, which publishes its heuristics and flags
them as unverified on hardware. Tune, don't trust:

| | |
| --- | --- |
| Start | A process starts capturing mic input — begin speculatively |
| Confirm | No far-end audio within **60 s** → discard, it was a mic test |
| End | Mic released for **45 s** → the meeting is over |
| Reconnect | Re-acquisition within **2 minutes** merges into the same meeting |
| Blip filter | Under **90 s** → drop |

The reconnect window is the detail worth keeping: dropped calls and "let me
rejoin" are routine, and without it one meeting becomes two.

Our end signal is better than the commercial products': mic release is an
audio-stack event, so it fires identically in Safari and Firefox, where Wispr
Flow's auto-stop — watching windows, needing Accessibility — does not.

**No calendar.** Granola uses the scheduled end time as a second end signal;
we do not need it, and it costs a permission and an account connection.

## Consent

Ask once, after the far end is confirmed — not when the mic is grabbed. The
confirmation step is what makes the prompt trustworthy: by then it is a call,
not a mic test.

The pill already does prompts (`OverlayPanel` has `.copyPrompt` and
`.learned`). Reuse it.

> **Record this meeting?** · Record · No

"No" holds until that app drops input. A second "No" for the same app means
never ask for it again, listed in settings so it is undoable — learned from
the user, never guessed. One setting governs the prompt: *Ask* (default) or
*Never*. Nothing auto-records.

The menu bar shows recording state for the whole recording. Recording other
people is the user's call to make with them; the app's job is to never do it
invisibly, and the prompt is the moment they can say so.

## Capture

Two tracks, never mixed for attribution:

| Track | Source | Is |
| --- | --- | --- |
| Mic | the existing `AudioCapture` | you |
| Far end | Core Audio process tap on the resolved PID | them |

That split is exact and free. It is also what Granola falls back to when its
platform hooks are unavailable, labelled "Me" and "Them" — the industry
default, not a shortcut.

One qualifier: on speakers rather than headphones, the mic picks up the far
end too. When both tracks are hot, attribute to the far end unless the mic
clearly leads. No echo canceller.

`insidegui/AudioCap` is the reference for the tap itself — Gui Rambo wrote it
because Apple shipped the API undocumented.

**Write raw, archive compressed.** `RecordingArchive` writes 16 kbps AAC,
which is right for playback beside a transcript and lossy enough to cost WER
on a re-run. Record 16 kHz mono Int16 (~115 MB per track-hour), transcribe
from that, then transcode to AAC and drop the raw.

**Dictation preempts.** Only one Parakeet stream can exist, and dictation
wins. The mic track keeps being written to disk throughout, so — unlike Wispr
Flow, whose docs admit your own voice is missing from the meeting transcript
while you dictate — nothing is lost. Those spans are recorded in the
metadata, and folded out of the meeting transcript by default: you were
talking to your notes, not to the room.

## Transcription

- **Live**: the mic only, streamed, exactly the dictation path. Nothing new.
- **At the end**: the far-end track is only written to disk during the call;
  one run over the tracks when the meeting ends.

Sequence the model loads — unload `parakeet-unified`, load the meeting model,
run, unload — so peak memory is the larger of the two, not the sum.

Estimate for the wait: `multitalker` runs ~207× realtime and the diarizer
~111× on an M4 Max, so the combined pass lands near ~70× — under a minute for
an hour, a few minutes on CPU or an older machine. It needs a progress state
in the pill, not a silent gap.

## Speakers

Three sources, best first:

1. **The meeting app's own UI.** Granola reads display names *and the
   active-speaker indicator* from the Zoom desktop app over Accessibility —
   no bot, no SDK, no cloud. **typemeit already holds Accessibility**
   (`Focus.swift`, `Frontmost.swift`), so this costs no new permission.

   Where it works it beats diarization outright: real names, no speaker cap,
   no label permutation, no second model. For Meet the equivalent is a browser
   extension reading the DOM — a whole other shipping surface, and out of
   scope.

2. **Diarization** for everything else — browsers, in-person, any app whose
   tree we cannot read.

3. **The mic/tap split**, which always gives "You" correctly, and anchors
   whichever arrival-order ID lines up with the mic track.

### Which diarizer

Undecided, and worth a spike before building.

`FluidAudio` (Apache-2.0/MIT models, CoreML) offers Pyannote offline, LS-EEND
streaming to **10 speakers**, and Sortformer; plus **dual-track** diarization
of separate mic and system streams, and **speaker embeddings** for identity
across meetings. It runs on the **ANE, explicitly avoiding GPU/MPS** — which
answers the objection to diarizing during a call, when the GPU is contended.

Against the `multitalker` bundle it lifts the 4-speaker cap, solves names
without a calendar, and stays off the GPU. It costs a second model stack:
CoreML beside the GGUFs, two download and update paths, two runtimes.

Dictation stays on transcribe.cpp either way.

## The Meetings section

A new top-level area beside History and Insights. List → detail.

### On disk

A folder per meeting, readable all the way down, because a meeting is three
artifacts and should be portable, greppable and deletable as one thing:

```
Meetings/
  2026-09-19 1430 Weekly sync (Zoom)/
    transcript.md
    mic.m4a
    others.m4a
```

- `YYYY-MM-DD HHMM` first, 24-hour, so lexical sort is chronological.
- No colons: legal on APFS, broken in shells, URLs and half of everything else.
- Sanitise — strip `/`, collapse whitespace and newlines, no leading dot, cap
  around 80 characters. Same minute twice: append ` 2`.
- `Store` writes whole JSON files atomically. That is wrong for this: one
  folder per meeting, not one growing file.

**The title**, with no calendar to supply one:

1. The window title at start, over AX, with the app's own suffix stripped.
2. Generated from the finished transcript — Zoom's window title is usually
   just "Zoom Meeting".
3. The app name alone.

Renaming in the UI rewrites the folder. A human-readable name nobody can fix
decays into noise.

### transcript.md

Markdown body, YAML front matter, so grep, Spotlight, Obsidian and any script
all work on it unaided.

```markdown
---
started: 2026-09-19T14:30:12Z
ended: 2026-09-19T15:04:48Z
duration_s: 2076
app: us.zoom.xos
app_name: Zoom
window_title: Weekly sync
device: MacBook Pro Microphone
headphones: true
segments: [{start: 0, end: 1840}, {start: 1902, end: 2076}]
speakers: 3
you: speaker_2
talk_time_s: {speaker_1: 812, speaker_2: 394, speaker_3: 601}
dictations: [{at: 923, entry: 9F2C...}]
model: multitalker-parakeet-streaming-0.6b-v1-Q8_0
---

**You** · 0:14
Morning — shall we start with the deploy?
```

`segments` records reconnects, so a dropped call reads as one meeting with a
gap. `dictations` marks the spans where you were talking to your notes.

Talk ratio, length distribution and over-run are all things the Insights code
already knows how to present.

## Permissions

The process tap needs the system-audio recording grant (Privacy & Security →
Screen & System Audio Recording, "System Audio Recording Only"), plus its
usage-description key in `Info.plist` — confirm the exact key against the SDK.
A second grant in onboarding, beside Microphone and Accessibility.

Accessibility is already granted, so the speaker-name scrape adds nothing.

## Prior art

Read these before writing any of it.

**Liftable, Swift, macOS-native**

- [`insidegui/AudioCap`](https://github.com/insidegui/AudioCap) — the process
  tap, permission dance and aggregate device
- [`makeusabrew/audiotee`](https://github.com/makeusabrew/audiotee) — the same
  API end to end as a standalone Swift binary
- [`FluidInference/FluidAudio`](https://github.com/FluidInference/FluidAudio) —
  diarization, dual-track, speaker embeddings, on the ANE
- [`Mo7amed7osam/zoom-auto-admit`](https://github.com/Mo7amed7osam/zoom-auto-admit)
  — watches Zoom's Accessibility hierarchy, PID-scoped reads, and **ships a
  live AX tree inspector**. That inspector is how to find the element paths
  without guessing.

**Detection logic, worth reading not linking**

- [`brendanbank/atrium-pa-mac`](https://github.com/brendanbank/atrium-pa-mac) —
  the thresholds in the table above
- [`rom4lk/meeting-helper`](https://github.com/rom4lk/meeting-helper) — the
  also-running-output disambiguation
- [`chrisns/MacWhisperAuto`](https://github.com/chrisns/MacWhisperAuto) — its
  supported-app matrix doubles as a test plan

**Whole products**

- [`abhi-wan-kenobi/notare`](https://github.com/abhi-wan-kenobi/notare) —
  closest match: local-first notetaker *plus* dictation. A fork of
  [`anarlog`](https://github.com/fastrepl/anarlog), formerly Hyprnote.
- [`pasrom/meeting-transcriber`](https://github.com/pasrom/meeting-transcriber)
  — on-device, auto-records Teams/Zoom/Webex, dual-track speakers
- [`Zackriya-Solutions/meetily`](https://github.com/Zackriya-Solutions/meetily)
  — Parakeet plus diarization already shipping
- [`anshuman-pandey/open-granola`](https://github.com/anshuman-pandey/open-granola)
  — pre-meeting briefs and commitment tracking, as metadata ideas

Licences and activity need checking before depending on any of them; several
are young repos of unknown quality. The consistent finding across all of them
is that nobody has better detection than the CoreAudio signal.

## Verification

- Meet in Chrome, mic live → detected. Same in Safari, where the commercial
  products' auto-stop does not fire.
- Meet tab backgrounded behind another tab → still detected. This is the case
  a window-title check fails, and why we do not use one.
- Zoom and Teams native → detected, which is what proves the helper-process
  resolution works.
- Leave and rejoin within two minutes → one meeting with a gap, not two.
- A 30-second mic blip → no prompt, nothing kept.
- Krisp or Loopback running with no call → no prompt.
- Dictate mid-meeting → dictation transcribes normally, the meeting transcript
  keeps the far end, and the dictated span is marked.
- Nothing on the mic → the offline dictation path, unchanged.

## Open

1. **Does a meeting transcript go anywhere but the section?** The plan assumes
   stored only — no paste, no clipboard.
2. **Live speaker labels during the call, or only at the end?** Only-at-the-end
   keeps the diarizer at a cheap operating point.
3. **FluidAudio or the multitalker bundle.** Spike both.
4. **More than four speakers** — with LS-EEND the cap is ten, and the question
   goes away. With the bundle, decide whether to warn.
