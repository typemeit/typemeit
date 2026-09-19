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
3. **In-person meetings.** Started by hand, one track, everyone in the room.
4. **Speakers.** Who said what, named where the meeting app will tell us and
   recognised by voice where it will not.

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

## Two kinds of meeting

A meeting is either a **call** or **in person**, and almost every decision
below forks on it.

| | Call | In person |
| --- | --- | --- |
| Starts | Detected, then we ask | By hand — menu bar or a shortcut |
| Tracks | Two: mic and far end | One: the mic |
| "You" | Free and exact, from the track split | Voice print, or nothing |
| Other speakers | The meeting app's names, else diarization | Diarization only |
| Title | Window title, else the transcript | The transcript |

There is no signal to detect an in-person meeting, and there should not be:
auto-recording a room because someone started talking is the one behaviour
this app must never have. In person is a deliberate act — the menu bar item
and a shortcut — and the menu bar shows it recording the whole time.

Everything about detection below is about calls.

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

### Event-driven, not polled

Register an `AudioObjectAddPropertyListenerBlock` on
`kAudioHardwarePropertyProcessObjectList`, plus per-process listeners on
`IsRunning`, `IsRunningInput` and `IsRunningOutput`, reconciling the
per-process set whenever the list changes, and yield every fire into one
stream to re-snapshot from. Polling the same properties works, but pays for
itself in confirmation counts and cooldowns to damp the noise.

### Traps, all found the hard way by others

- **FaceTime's input belongs to `com.apple.avconferenced`**, a daemon —
  `com.apple.FaceTime` never reports input at all (measured on macOS 26.5.2).
  So resolution cannot assume the owner is a `.app`: tap the daemon, and
  expect no window and no participant list. A FaceTime *link* opened in a
  browser is `com.apple.WebKit.GPU` instead.
- **A process with no bundle answers `noErr` with an empty string**, not an
  error. `afplay` and friends have to be filtered explicitly.
- **Power assertions are a third channel**, and a tempting one: meeting apps
  hold `PreventUserIdleDisplaySleep` during calls, readable with
  `IOPMCopyAssertionsByProcess()`, no entitlement. It is also a minefield —
  newer Zoom builds name theirs with Apple's sample placeholder ("Describe
  Activity Type") so no keyword matches, and Teams holds a "Video Wake Lock"
  with no call in progress at all. Worth knowing about; not worth leading
  with.

The structure that holds all three is a composite detector: first confirmed
hit wins, and the meeting stays alive while *any* channel still sees it. We
lead with mic input, and that is where a second channel would go if one is
ever needed.

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

In person there is only the mic track, and with it goes the free "You" —
everyone in the room, you included, arrives in one mono channel. That is what
makes speaker recognition load-bearing rather than a nicety.

One qualifier: on speakers rather than headphones, the mic picks up the far
end too. When both tracks are hot, attribute to the far end unless the mic
clearly leads. Bleed is real enough that serious implementations of this ship
both a detector and a canceller for it — see **Echo** below for how far we go
and when.

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

## Echo

A call taken on speakers puts the far end back into the mic track. It costs
us twice: attribution stops being free, and a mixed signal carries the same
words twice, slightly offset, which is worse for the model than either track
alone. Headphones and in-person recordings have no echo at all, so this is
one case of three.

Three steps, cheapest first, and stop as soon as it is good enough:

1. **Do not mix.** We transcribe at the end, and the one-stream-per-model
   limit only bites on concurrent streams — so run the two tracks through the
   model one after the other and merge by timestamp. Each track is
   transcribed alone, the far end is never doubled in one signal, and
   attribution comes out exact instead of inferred. It costs roughly double
   the end-of-meeting wait, and it is free of new dependencies. This is
   better than mixing on every axis but time.
2. **Voice-processing I/O, meeting sessions only.** macOS will cancel echo on
   an input node for the asking. It also brings automatic gain control and
   noise suppression with it, which is why it must never be switched on for
   the shared dictation path — that would move dictation WER, and dictation
   is the product. Measure before and after.
3. **A dedicated AEC model, only if 1 and 2 leave audible bleed.** Small
   streaming cancellers exist under Apache-2.0 at a few MB, bundled rather
   than downloaded. By the time we know whether it is warranted we will have
   real recordings to judge it on.

Whatever we do, quarantine embeddings suspected of bleed before they reach a
speaker's centroid — see above. That guard is worth having even at step 1.

## Speakers

Which sources exist depends on the kind of meeting. In person, only the last
one does — which is why diarization is now required rather than a fallback.

Three sources, best first:

1. **The meeting app's own UI.** Granola reads display names *and the
   active-speaker indicator* from the Zoom desktop app over Accessibility —
   no bot, no SDK, no cloud. **typemeit already holds Accessibility**
   (`Focus.swift`, `Frontmost.swift`), so this costs no new permission.

   Where it works it beats diarization outright: real names, no speaker cap,
   no label permutation, no second model. For Meet the equivalent is a browser
   extension reading the DOM — a whole other shipping surface, and out of
   scope.

   None of this is verified beyond Zoom, and not on a version we have
   checked. The probe below runs before phase 3 leans on it.

2. **Diarization** for everything else — browsers, in-person, any app whose
   tree we cannot read.

3. **The mic/tap split**, which on a call always gives "You" correctly, and
   anchors whichever arrival-order ID lines up with the mic track.

### The AX probe, before anything is built on it

Source 1 is unproven. It works somewhere, on some version of one app. Nothing
tells us whether the tree is readable with the participants panel closed,
whether the active-speaker indicator updates fast enough to segment on, or
whether any of it survives an app update. Run the inspector against a real
call on each platform and write the answers down before phase 3 commits to
this path.

For each app, four questions:

- **Names.** Is the participant list in the tree at all, and does it carry
  real display names or just row indices?
- **Panel closed.** Does it still read with the participants panel hidden —
  the normal state — or does AppKit only build those children when visible?
  If it needs the panel open, the source is dead for most calls.
- **Active speaker.** Is there an attribute that changes as people talk, how
  fast does it settle, and is the latency stable enough to cut segments on?
- **Churn.** Does it survive joins, leaves, renames, screen share, and
  gallery vs speaker view?

| App | Expectation | Why it is worth the probe |
| --- | --- | --- |
| Zoom | Best odds — native AppKit, and this is the app the technique is known to work against | The most common call |
| Teams | Poor — Electron, so the tree is whatever the web content exposes | Common enough that "no names on Teams" is a real gap |
| Slack huddles | Poor, same reason | Asked for explicitly |
| Webex, Discord | Unknown | Cheap to check once the harness exists |
| Meet, any browser | Assume no — DOM, not AX, and an extension is out of scope | Rules the source out for the most common case, which is why 2 and 3 have to stand alone |

Ship the probe as a throwaway tool, not app code: a command that attaches to
the frontmost meeting window, dumps the tree, and polls the candidate
attribute for thirty seconds so the timing is measured rather than guessed.
Record the result per app and per app version — an update can take it away,
so whatever is built on it degrades to diarization rather than breaking.

### "You", in a room

In person the split is gone, so "You" has to be recognised by voice. The app
is in an unusual position here: **every dictation ever made is a clean,
labelled recording of the user speaking alone.** `RecordingArchive` is a
voice-print enrolment corpus that a notetaker cannot have and does not need
to ask for.

Enrol from it once, match against the diarizer's speaker embeddings, and
"You" is identified in a room the same way it is on a call. The same
embedding answers the browser case, where the meeting app gives us no names
at all.

The established shape is worth following: per speaker keep a **centroid** (running mean of every confirmed
embedding) plus a short FIFO of recent samples, match on the smaller cosine
distance of the two, and accept only past a **0.40 distance threshold** with
a **0.10 margin** over the runner-up. Fold only quality-filtered samples into
the centroid — short snippets stay as fallback anchors — and **quarantine
embeddings suspected of echo bleed**, or a speakerphone will poison a
participant's print with the user's own voice.

The usual enrolment is a sheet: pick a file, diarize it, name the speakers by
hand. Ours needs no sheet for the user — every kept dictation is already a
labelled recording of one known speaker. That sheet is still worth building
later for *other* people, since naming a voice from a past meeting is now the
only route to real names.

Two things to get right: enrol from recordings the user kept, never from
audio they asked not to keep; and let them turn it off, since a stored voice
print is a different kind of data from a transcript.

### Which diarizer

In person probably settles this. A meeting room holds more than four people,
and a four-speaker cap merges the rest into the wrong mouths — which rules
out the `multitalker` bundle and Sortformer for the case we now have to
support.

`FluidAudio` (Apache-2.0/MIT models, CoreML) offers Pyannote offline, LS-EEND
streaming to **10 speakers**, and Sortformer; plus **dual-track** diarization
of separate mic and system streams, and **speaker embeddings** for identity
across meetings. It runs on the **ANE, explicitly avoiding GPU/MPS** — which
answers the objection to diarizing during a call, when the GPU is contended.

Against the `multitalker` bundle it lifts the 4-speaker cap, gives us the
voice prints that "You" in a room depends on, and stays off the GPU. It costs
a second model stack: CoreML beside the GGUFs, two download and update paths,
two runtimes. For in-person that cost looks unavoidable.

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
kind: call
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
gap. `dictations` marks the spans where you were talking to your notes. An
in-person meeting carries `kind: in-person`, no `app` or `window_title`
fields, and its folder is named from the generated title alone —
`2026-09-19 1430 Roadmap review`.

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

**Check the licence before reading, every time.** Several mature projects in
this space are *source-available* rather than open source, under licences
that forbid use in a competing product. We are one. Where this plan states a
technique — the process-object listeners, the tap geometry, the matcher
thresholds, the echo ladder — it is sourced from Apple's documentation or
from MIT-licensed code, and it should stay that way.

**Whole products**

- [`abhi-wan-kenobi/notare`](https://github.com/abhi-wan-kenobi/notare) —
  closest match: local-first notetaker *plus* dictation. A fork of
  [`anarlog`](https://github.com/fastrepl/anarlog), formerly Hyprnote.
- [`iamchuck504/yapper`](https://github.com/iamchuck504/yapper) — detects
  which app holds the mic, including Slack, and offers to record in a
  notification. Our gate and our prompt, already built.
- [`alejacre/meetscribe`](https://github.com/alejacre/meetscribe) —
  configurable triggers by bundle ID, Slack included
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
- In person, six people round a table → started by hand, one track, no
  four-speaker merge, and "You" found by voice print.
- In person with the voice print off → speakers stay unnamed, everything else
  works.
- A FaceTime call → detected through `avconferenced`, tapped there, and the
  missing window title falls through to a generated one.
- A voice message longer than a few seconds → no recording. Mic-input
  detection alone fails this, which is what the far-end confirmation and the
  blip filter are for.
- AX probe, per app in the table above → names present, panel-closed answer
  recorded, active-speaker latency measured. A "no" on any app is a result,
  not a blocker: that app falls through to diarization.
- Zoom updates → the probe reruns and the attribution degrades to diarization
  rather than throwing or mislabelling.

## Open

1. **Does a meeting transcript go anywhere but the section?** The plan assumes
   stored only — no paste, no clipboard.
2. **Live speaker labels during the call, or only at the end?** Only-at-the-end
   keeps the diarizer at a cheap operating point.
3. **FluidAudio or the multitalker bundle.** Spike both, though in person
   points hard at FluidAudio.
4. **Voice-print enrolment** — opt in or on by default, and what happens to
   the print when the user clears their history.
