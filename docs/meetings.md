# Meetings

A build spec. It says what to build, in what order, and how to know each step
is done. Dictation stays what it is; this adds a second thing the app does:
notice a call, ask once, record both sides, transcribe when it ends, and keep
the result in a Meetings tab. A meeting in a room is the same thing started by
hand.

Nothing here is built. The streaming-dictation commit on this branch is not
part of the plan; see section 15.

## Contents

1. What ships, in order
2. Decisions
3. Facts this rests on
4. Working in this repo
5. Architecture
6. Spikes
7. Phase 1: calls
8. Phase 2: the room, and speakers
9. Phase 3: names
10. Later
11. Copy
12. Tests
13. Traps
14. Prior art and licences
15. Changes from the earlier draft

## 1. What ships, in order

| Step | Delivers | Done when |
| --- | --- | --- |
| Spikes S1 to S3 | Measured answers to the unknowns in 3.5, written into this file | Every pass/fail line in section 6 is filled in |
| Phase 1 | Slack huddles and Google Meet detected; one prompt, with the two minutes before it kept; two tracks recorded on one clock; transcript with **You** and **Them**; a Meetings tab; import a recording | The phase-1 verification list (7.13) passes on a real huddle and a real Meet call |
| Phase 2 | The room, started by hand; far-end and room speakers numbered by diarization and renameable | 8.5 passes with three people on a call and six in a room |
| Phase 3 | **You** recognised in a room by voice print; names recovered from the meeting window where the probe says they can be | 9.3 passes; anything the probe failed stays as numbers |

Each phase is shippable on its own. Phase 2 adds fields to phase 1's files and
changes none. Inside phase 1 the build order (7.1) is settings, capture
without a tap, the recorder, storage, transcription and the tab first,
exercised through a dev-only mic recording, then process objects, the watch,
the machine, the coordinator and the tap. That puts the code that can be
tested alone first and the code that needs a second person last.

## 2. Decisions

Each is settled here so the implementer never has to guess. The owner can
change any of them; the default is what gets built.

- **D1. Targets.** Slack huddles (the Slack app) and Google Meet (Chrome and
  Safari; Safari's audio lives in a process every web app shares, so its
  meetings are named `web content`, 7.2). Everything else works if the gate
  fires for it, and nothing else is
  tuned or tested for release.
- **D2. Detection is a boolean, resolved to an app.** Any process other than
  ours running microphone input, per CoreAudio's process objects. The process
  is resolved to the app that owns it, so a Chrome or Slack helper counts as
  Chrome or Slack. The resolved app is never matched against a list of
  meeting apps. It is used to pick the processes to tap, to tell two mic
  holders apart, to name the prompt and the folder, and as the key of the
  never-ask list.
- **D3. Nothing is captured before the user says record.** A call is
  confirmed from two booleans, input and output both running on the same app
  for `Fixed.meetingConfirmSeconds` (12 s), never from tapped audio. The
  opening seconds of a call are therefore not recorded. That is the price of
  asking first.
- **D4. Consent is one prompt in the pill, plus a menu item.** The pill asks
  once and stays until answered or until the app drops the mic; it has no
  timer. The menu carries *Record This Meeting* whenever a call is detected
  and nothing records: after a cross, for an app on the never-ask list, and
  for a call already running when the app launched. The cross means not this
  call, and is remembered for the whole call including a drop and rejoin of
  up to two minutes. A recording survives a drop of up to 30 s and the pill
  says so when it resumes; a longer gap ends the meeting and the next call
  asks again. *Don't Ask for Slack Again* is an explicit menu item, listed in
  settings where it can be undone; nothing is ever inferred from repeated
  crosses. A setting turns asking off entirely. Nothing records without a
  click.
- **D5. Two tracks, one clock.** The mic and the far end are captured by one
  private aggregate device that contains the microphone as a sub-device and a
  Core Audio process tap on every process of the resolved app, driven by one
  IO proc. Both tracks are sample-aligned by construction and written to disk
  as they arrive. Dictation keeps its own `AudioCapture` engine and is not
  changed.
- **D6. Transcription happens when the meeting ends, with the model already
  installed.** `parakeet-unified-en-0.6b` transcribes each track on its own,
  offline, in chunks of at most `Fixed.meetingChunkSeconds` (120 s) cut at
  quiet points, on a second transcribe.cpp session with its own abort flag. No
  second speech model, no live transcription. Speaker labels come from the
  track split (**You** / **Them**) in phase 1 and from FluidAudio diarization
  of the far-end or room track in phase 2.
- **D7. FluidAudio's offline pipeline is the diarizer.** Pyannote community-1
  segmentation plus WeSpeaker embeddings plus VBx clustering
  (`OfflineDiarizerManager`), pinned to `.cpuAndNeuralEngine`, Apache-2.0
  library, CC-BY-4.0 weights. Not the multitalker bundle (4-speaker cap, no
  embeddings, NVIDIA licence, a second 873 MB download). Its model files are
  mirrored to a GitHub release and hash-pinned like the speech model, and
  loaded from disk; the app never fetches from Hugging Face.
- **D8. Storage is a folder per meeting; `meeting.json` is the truth and
  `transcript.md` is rendered from it.** Foundation has no YAML parser and the
  app never parses a file the user may edit. The Markdown carries flat front
  matter for grep and Obsidian; the JSON carries everything.
- **D9. Meetings are staged under `Store.directory` and published to a
  folder setting.** Raw tracks and the in-progress record live in
  `Store.directory/Meetings/.in-progress/<id>/`, excluded from backup. When a
  meeting is transcribed its folder moves to `Settings.meetingsFolder`, which
  defaults to `Store.directory/Meetings`. The Meetings tab has `show` and
  `change`; a folder chosen in the open panel is where Spotlight and Obsidian
  users put it, and the row's subtitle says `icloud drive` when the folder is
  inside iCloud Drive's container (`~/Library/Mobile Documents/com~apple~CloudDocs`).
- **D10. A meeting transcript goes nowhere but the Meetings tab.** No paste,
  no clipboard beyond the row's copy button, no Apple Intelligence clean-up.
  `PostProcessor.shared` cancels whatever it was doing when called again and
  the on-device model's window is 4,096 tokens, so neither the shared
  instance nor a whole meeting fits.
- **D11. The room is started by hand only.** A menu item and an optional
  shortcut. There is no signal that detects an in-person meeting and there
  must not be one.
- **D12. Dictation during a meeting keeps working and is folded out of the
  transcript.** The mic track keeps recording; the dictation's span is
  recorded in `meeting.json` as a frame range and the mic words inside it are
  dropped from the meeting transcript. While a meeting records, dictation
  does not mute output, pause media, or play its cues.
- **D13. The system-audio grant is asked for at the first record click.**
  macOS prompts when the tap starts. There is no public API to check the
  grant and a tap without it delivers exact zeros with no error, so the
  recorder watches for both tracks at the floor for
  `Fixed.meetingSilentSeconds` (90 s) and the Meetings tab has a `test`
  button that taps our own process and checks for signal. The mic track is
  kept whatever the far end does.
- **D14. Echo is detected, never removed.** Every two-track meeting is run
  through an envelope cross-correlation detector at the end. An affected
  meeting is marked `echo: affected`, its row says `on speakers`, and
  nothing is deleted from either transcript. Voice-processing I/O and text
  dedup are out (section 10).
- **D15. Voice prints are opt-in and die with history.** The **You** print
  is built only when the user turns it on, from kept dictation recordings
  and from dictations as they happen, and deleted when they turn it off or
  clear their history.
- **D16. Live speaker labels are out.** Everything speaker-related runs
  after the meeting.
- **D17. The meeting has its own busy state.** `AppState.meeting` is set by
  the coordinator, not derived from `Pipeline.phase`. The puff draws a
  separate mark for it, Sparkle's relaunch waits for it, and quit stops it
  before the process exits.
- **D18. No voice but the user's is ever stored, and the user's only opt-in
  (D15).** Far-end and room speaker embeddings exist for one transcription
  pass, in memory, and are never written to disk or to `meeting.json`.
- **D20. A meeting keeps the minute before the user says yes.** Capture
  starts when an owner becomes a candidate, into memory only. On `record`
  the buffer becomes frame 0 of the tracks; on `decline`, on the candidate
  lapsing, and on quit it is freed and nothing is written. Without it a
  meeting starts at the click, which is after the part that says what the
  meeting is about. The cost is that the microphone opens before consent —
  visibly, since macOS lights its indicator — and the settings row says so.
- **D21. A recording made elsewhere can be imported.** One file in, the same
  pipeline, a meeting out. It covers what detection cannot see (a phone
  call, a room recorded on a phone, a call the user declined) and it is how
  S2 and S3 get an hour of real audio without staging a meeting.
- **D22. Meetings are queryable over MCP, read-only, off by default.** A
  stdio binary in the app bundle reads the published folders directly, so it
  needs no port, no auth and no running app. It is the one path by which
  meeting text can leave this Mac, so it is a switch the user throws and the
  help says what it means.
- **D19. The other participants are not told.** The app announces nothing to
  the call. Recording someone may need their agreement where the user is;
  the Meetings tab footer says so in one line.

## 3. Facts this rests on

Verified on 2026-09-19 against the sources named. "Measured" means run on
this Mac (macOS 26.6.2, Xcode 27.0) with a throwaway Swift binary; the probe
sources are listed at the end of the section.

### 3.1 transcribe.cpp v0.2.3 (`transcribe.h`, `docs/models/*.md`)

- At most one `transcribe_run` or active stream may be in flight across all
  sessions of one loaded model. Many sessions on one model, used one at a
  time, is supported, and the abort callback is per session (header,
  threading contract and `transcribe_set_abort_callback`).
- `parakeet-unified-en-0.6b` offline uses full attention over the whole
  input. The library sets no length limit for Parakeet and says nothing
  about memory on an hour of audio. Its buffered-streaming mode re-encodes a
  `5.6 s | 1.04 s | 1.04 s` window per step, about 7.4 times the encoder
  work of offline for the same audio. Offline Q8_0 runs at about 158x
  realtime on an M4 Max on Metal (11 s in 69 ms).
- Word rows carry `t0_ms`/`t1_ms` relative to the input audio and a
  per-token probability. `Transcriber.words(of:)` already reads them.
- The multitalker bundle is offline-API only, capped at four speakers by its
  embedded Sortformer, 873 MB at Q8_0, NVIDIA Open Model License. The plain
  multitalker GGUF produces no speaker ids at all. Sortformer's labels are
  arrival-order and can swap mid-recording on a near-tie.
- MOSS grows about 85 MB of memory per minute of audio and does not stream.
- The shipped dylib imports `fopen`/`fread` and no `mmap`: a second loaded
  model is a second resident copy (`nm -u` on the framework binary).
- The speech model's licence is CC-BY-4.0 (attribution already owed).

### 3.2 Core Audio process objects and taps

Sources: the macOS 27.0 SDK headers, `insidegui/AudioCap`,
`pasrom/meeting-transcriber`, and the probes below.

- Process objects: `kAudioHardwarePropertyProcessObjectList` on the system
  object; per process `kAudioProcessPropertyPID`, `BundleID`, `IsRunning`,
  `IsRunningInput`, `IsRunningOutput`, `Devices`;
  `kAudioHardwarePropertyTranslatePIDToProcessObject`. Apple states no
  minimum macOS for these. `MediaPause.playingProcesses()` already reads
  them.
- **Measured: listeners on `IsRunningInput` and `IsRunningOutput` register
  with `noErr` and never fire**, on our own process object and on another
  process's, while the values change. `IsRunning` fires for output
  transitions only. The notification CoreAudio does deliver on an input or
  output transition is `kAudioProcessPropertyDevices` (`pdv#`), once per
  scope (`inpt`, `outp`), within about 60 ms; a listener at global scope
  does not fire. `kAudioHardwarePropertyProcessObjectList` fires when a
  process object appears or goes, four to six times for one `afplay`
  launch, and not at all when an existing object opens the mic, which is
  every browser and Electron call (their audio helpers exist before the
  call).
- A process with no bundle answers `noErr` with an empty string.
- **Measured: helpers report their own bundle ids**: `com.google.Chrome.helper`,
  `com.tinyspeck.slackmacgap.helper`. Chrome's and Slack's browser processes
  carry no audio streams; each Chromium or Electron app runs one
  `AudioService` helper that owns both capture and playback. Spotify's main
  process shows output while its helper does not, so "running output" is a
  property of the app's process set, not of one process. Safari's audio is
  `com.apple.WebKit.GPU` under `/System/Volumes/Preboot/Cryptexes/…` with no
  `.app` in its path.
- FaceTime's input belongs to `com.apple.avconferenced`, a daemon; a FaceTime
  link in a browser is `com.apple.WebKit.GPU` (meeting-transcriber
  `MicInputDetector.swift`, measured on macOS 26.5.2 by that project).
- Tap: `CATapDescription(monoMixdownOfProcesses:)`, `AudioHardwareCreateProcessTap`
  (`API_AVAILABLE(macos(14.2))`), an aggregate device with
  `kAudioAggregateDeviceTapListKey`, `kAudioSubTapUIDKey`,
  `kAudioSubTapDriftCompensationKey`, `kAudioAggregateDeviceTapAutoStartKey`,
  `kAudioAggregateDeviceIsPrivateKey`, `AudioDeviceCreateIOProcIDWithBlock`,
  `AudioDeviceStart`. The tap's format is `kAudioTapPropertyFormat` on the
  tap object (the system's rate, typically 48 kHz). The tap "is used as an
  input in a HAL aggregate device, just like a microphone" (Apple). The
  default `muteBehavior` is unmuted.
- `kAudioTapPropertyDescription` "can be used to modify and set the
  description of an existing tap" (SDK). macOS 26 adds
  `CATapDescription.bundleIDs` (tap by bundle id) and
  `processRestoreEnabled` (a tapped process that exits and relaunches under
  the same bundle id rejoins the tap). Both untested here; S1 tests them.
- The grant is *System Audio Recording Only* under Privacy & Security ›
  Screen & System Audio Recording, keyed by `NSAudioCaptureUsageDescription`
  in `Info.plist` (absent from the project today). The prompt reads
  "“type me it dev” would like access to record your system audio." There is
  no public preflight or request call. A tap without the grant delivers
  buffers of exact zeros and no error. When the grant is switched on in
  System Settings while the app runs, macOS offers "Quit & Reopen" and says
  the app "may not be able to record the audio from running applications
  until it is quit". The pane deep link anchor `Privacy_AudioCapture` exists
  in the Settings binary (untested).
- Teardown order that does not corrupt the file: `AudioDeviceStop`,
  `AudioDeviceDestroyIOProcID`, a barrier onto the write queue,
  `AudioHardwareDestroyAggregateDevice`, `AudioHardwareDestroyProcessTap`
  (meeting-transcriber `AppTapSession.swift`).

### 3.3 FluidAudio (README, `Documentation/Diarization/*.md`, `Package.swift`, `Sources`)

- Library Apache-2.0. Model weights on Hugging Face: the pyannote/WeSpeaker
  bundle is CC-BY-4.0 (attribution required in the app), Sortformer CC-BY-4.0
  plus the NVIDIA licence, LS-EEND MIT. macOS 14 or newer.
- Offline pipeline: `OfflineDiarizerManager`, pyannote community-1 plus
  WeSpeaker 256-d L2-normalised embeddings plus VBx. No speaker cap. Best
  measured DER of FluidAudio's diarizers (AMI-SDM 10.6%). Average RTFx about
  122 at the default `stepRatio 0.2`, about 65 at `stepRatio 0.1`, which
  FluidAudio's docs say measures best on far-field meetings with rapid
  exchanges. `DiarizationResult.speakerDatabase` gives one embedding per
  speaker. The default compute units are `.all`, which includes the GPU; the
  README's "avoids GPU/MPS" is not the default for this pipeline.
- The offline pipeline's model files are `Segmentation`, `FBank`,
  `Embedding`, `PldaRho` (`.mlmodelc`) plus `plda-parameters.json`
  (`Sources/FluidAudio/ModelNames.swift`), not the `pyannote_segmentation`
  and `wespeaker_v2` files the manual-loading doc names for the streaming
  pipeline. Local loading without network is supported for both.
- Streaming diarizers are not used here: LS-EEND (10 speakers on `dihard`
  variants, 4 on `ami`, 8 kHz input, unstable enrolment) and Sortformer
  (4 speakers). Sortformer's offline mode confuses speakers on long files.
- The clustering threshold's meaning inverted in FluidAudio #801; do not
  copy values from older posts.
- "Dual-track diarization" is not a FluidAudio feature. It is
  meeting-transcriber's own code (`DiarizationProcess.mergeDualSourceSegments`).
- FluidAudio 0.15.6 added a binary target whose root-level module map
  collides with other static-library xcframeworks under `xcodebuild`.
  TranscribeCpp ships framework slices, so with one static-library artifact
  the collision does not arise today; it re-arms if a second is ever added.
  Latest release at time of writing: 0.15.7.

### 3.4 This app (origin/main at e0bdb8e, 20 September 2026)

- `AudioCapture` is one `AVAudioEngine`; `start` clears its buffer and opens
  the engine, `stop` closes it and returns the whole recording. It is
  single-consumer by construction and is left that way (D5).
- `Transcriber` is an actor holding one model and one session, unloaded after
  five idle minutes, with one abort flag on that session; a dictation cancel
  would abort anything else on it. `ensureLoaded` hardcodes
  `ModelStore.modelURL`.
- `RecordingArchive.save` encodes a whole `[Float]` through one
  `AVAudioPCMBuffer`; there is no file-to-file path. `RecordingPlayer.toggle`
  takes a `HistoryEntry` and resolves under `Store.directory/Recordings`.
- `Store.prune` and the History tab's keep picker cover dictations only.
- `MediaPause.playingProcesses()` walks the process object list and reads
  `PID`, `BundleID` and `IsRunningOutput` (since PR #149).
- Screen Recording is already used, opt-in, by `ScreenContext.captureLines(pid:)`
  (ScreenCaptureKit capture of the frontmost window of a pid, Vision OCR,
  frame discarded) and `ScreenSampler`; both request the grant on toggle.
- Accessibility is required and polled every second (`MissingPermission`).
- `ModelStore` handles exactly one hash-pinned model from a GitHub release;
  the Makefile publishes it.
- `OverlayModel.State` has pill states with a left icon slot, a label, one
  primary button and a cross; `OverlayPanel.show` replaces the state with no
  queue, and `Pipeline.beginRecording` shows the cloud unconditionally. The
  panel never sets `sharingType`, so it is captured by a display share.
- `AppState.recording` is recomputed from `Pipeline.phase` on every change.
  `MenuBarIconRenderer.puff` has four states: orange while the mic is open,
  faded arcs while transcribing, a slash for a lost permission, a dot at the
  top right for a ready update.
- `Updates.installWhenIdle` relaunches for an update as soon as
  `Pipeline.shared.phase == .idle`. Quit runs `applicationWillTerminate`,
  which calls `_exit(0)` on purpose; nothing is closed on quit.
- `Pipeline.beginRecording` mutes the default output device
  (`muteWhileRecording`, default on) or presses play/pause
  (`pauseWhileRecording`), and plays cues (`audioFeedback`, default on).
- `PostProcessor.shared.run` cancels its current task when called again. Its
  instructions are about 530 tokens of a 4,096-token window.
- `keepRecordings` defaults to off in release builds and kept audio is pruned
  with history, so the dictation archive is usually empty (relevant to D15).
- The DMG build is not sandboxed. A Mac App Store build would be
  (`docs/app-store.md`; no store target exists yet): `Sandbox.isActive`
  detects the container, `Sandbox.readsOtherApps` gates every Accessibility
  read of another app, and `SettingsTab.available` hides the insights tab
  there. `Store.directory` is `~/Library/Application Support/TypeMeIt`
  (or `TYPEMEIT_SUPPORT_DIR` when set), hidden in Finder and not surfaced
  by Spotlight.
- The app's only entitlement is `com.apple.security.device.audio-input`;
  `Scripts/release-dmg.sh` fails the release when the signed set is anything
  else. Process taps, the system-audio grant and the Documents folder need
  Info.plist usage strings, not entitlements.
- `Fixed` holds tuning constants with the measurement that set them in a
  comment; `learningAppDenylist` is the precedent for a bundle-id list.
- Electron honours `AXManualAccessibility` set on the app element; Chrome
  honours only `AXEnhancedUserInterface`, debounced by 2 s, and both put the
  process into full screen-reader mode (Electron docs; Chromium
  `chrome_browser_application_mac.mm`). Google documents Meet's participant
  panel as screen-reader navigable; whether tiles carry names is unverified.

### 3.5 Unverified, each owned by a spike

| Assumption | Spike |
| --- | --- |
| A private aggregate device with the mic as a sub-device and a process tap delivers both tracks through one IO proc, sample-aligned, on built-in, USB and Bluetooth devices | S1 |
| Slack's and Chrome's helper bundle ids resolve to the running app by prefix, and input and output land on the same helper during a call | S1 |
| `kAudioProcessPropertyDevices` listeners plus a 1 s poll catch every mic acquisition the UI shows | S1 |
| `CATapDescription.bundleIDs` covers helper bundle ids, and `kAudioTapPropertyDescription` can be set on a live tap | S1 |
| The grant takes effect without relaunching the app when granted from the prompt; and needs one when toggled in System Settings | S1 |
| A CAF written with a `-1` data chunk size opens in `AVAudioFile` after a `kill -9` | S1 |
| Offline `transcribe_run` on a 120 s chunk is fast and memory-bounded; the seam WER cost is small; one run over an hour is not bounded | S2 |
| FluidAudio's offline diarizer loads from a local directory with no network, builds in this Xcode project, and runs at 30x realtime or better (an hour in two minutes) | S3 |
| WeSpeaker embeddings from kept dictations separate the user from other speakers at cosine distance 0.40 with a 0.10 margin | S3 |
| Chromium exposes Meet's tiles, and Slack its huddle roster, in the accessibility tree once the activation attribute is set | S4 (phase 3) |
| `AudioHardwareCreateProcessTap` works inside the App Sandbox | none; checked when a store target exists (section 10) |

The probes behind the measured facts are in `docs/meetings-probes/`, each a
single file that builds with `xcrun swiftc -O -o /tmp/probe <file>`:
`dumpprocs.swift` (every process object with pid, bundle, path and flags,
plus a process-list listener), `listeners-self.swift` (a wildcard listener
on our own process object while the mic opens and closes: only `pdv#`
fires) and `listeners-other.swift` (the same on another process's object
while that process plays a sound: `IsRunningOutput` listeners never fire;
it takes the path of a compiled `audio-child.swift` as its argument). None
creates a tap, so none prompts for the grant.

## 4. Working in this repo

Build and run the dev app exactly as `CLAUDE.md` says; only one dev instance
runs at a time. Tests:

```sh
xcodebuild -project TypeMeIt.xcodeproj -scheme TypeMeIt -derivedDataPath build/dd test
```

Rules for every task below:

- Constants go in `enum Fixed` (`Settings.swift`), named `meeting…`, each
  with a comment naming the measurement or source that set it. No bare
  numbers in the code.
- Every user-visible string is in section 11. Counts go through
  `counted(n, "noun")`. Pill, settings and tab text is lowercase, and so are
  the settings window's tooltips (`play the audio`, `delete`); menu items and
  dialog buttons are Title Case; the pill's cross tooltip is Title Case like
  `Cancel` and `Dismiss` today, hence `Not now`.
- New log category `Log.meetings`. Every state change in the watch, the
  machine, the recorder and the transcriber writes one `DebugLog` line
  (state, app, elapsed, event) when debug logs are on.
- Pure logic lives in enums or structs with no dependencies, tested in
  `TypeMeItTests` with plain XCTest and no audio hardware. Anything that
  touches CoreAudio, files or the screen is a thin shell around such a type.
- One file per module under `TypeMeIt/Meetings/`, tests under
  `TypeMeItTests/Meetings/`.
- Every audio callback (the aggregate's IO proc) copies into a preallocated
  ring buffer and returns. No allocation, no lock, no Swift concurrency
  inside it.
- Every timer uses `ContinuousClock`, which keeps counting through sleep.
  `Date` is for display and for `meeting.json`.
- Probes are launch arguments on the dev app, read with
  `UserDefaults.standard` like `-previewToast` is today, and are removed
  before the phase ships.
- Lifted code carries a comment naming its source and licence (section 14).

## 5. Architecture

### 5.1 New files

| File | Owns |
| --- | --- |
| `Meetings/AudioProcesses.swift` | Reading CoreAudio process objects into `[AudioProcessInfo]`; the listeners; the pure `ProcessOwner` resolver |
| `Meetings/MeetingWatch.swift` | The reconciled "which apps hold input and output" set, debounced, delivered on the main actor |
| `Meetings/MeetingMachine.swift` | The pure state machine (states, events, timers, effects) |
| `Meetings/MeetingCoordinator.swift` | `@MainActor` owner of the machine: feeds it watch updates and ticks, shows the prompt, starts and stops the recorder, hands finished meetings to the transcriber, exposes the busy state |
| `Meetings/MeetingCapture.swift` | One private aggregate device (mic sub-device plus optional process tap), one IO proc, two ring buffers, the drain queue, device-change rebuilds |
| `Meetings/AudioRing.swift` | A preallocated single-producer single-consumer Float32 ring |
| `Meetings/PreRoll.swift` | One ring per track sized in seconds; `take()` drains oldest-first and frees; `discard()` zeroes and frees |
| `MCP/main.swift`, `MCP/Protocol.swift`, `MCP/Tools.swift` | The `typemeit-mcp` target: JSON-RPC framing (pure), the four tools over the meetings folder (pure over a directory) |
| `Meetings/MeetingImport.swift` | Any file `AVFoundation` can read to a 16 kHz mono `.caf` in a staged folder, plus the `Meeting` that describes it |
| `Meetings/TrackWriter.swift` | Appends Float32 to a CAF file as Int16 with an open-ended data chunk; silence fill; peak tracking |
| `Meetings/MeetingRecorder.swift` | Owns a `MeetingCapture` and one or two `TrackWriter`s; the silence monitor; gaps; dictation spans; levels |
| `Meetings/Meeting.swift` | `Meeting` (Codable) and its parts |
| `Meetings/MeetingFolder.swift` | Folder naming and sanitising (pure); create, publish, rename, recycle; transcode |
| `Meetings/MeetingStore.swift` | `@MainActor @Observable` list of meetings; save, rename, delete, prune, disk usage; the folder watcher; launch recovery |
| `Meetings/TranscriptRender.swift` | `meeting.json` to `transcript.md` (pure) |
| `Meetings/ChunkCutter.swift` | Cut points for a long track from its peak envelope (pure) |
| `Meetings/TranscriptMerge.swift` | Words from one or two tracks plus speaker segments plus dictation spans to paragraphs (pure) |
| `Meetings/EchoBleedDetector.swift` | Lifted from meeting-transcriber (MIT): envelope cross-correlation verdict (pure) |
| `Meetings/MeetingTranscriber.swift` | The end-of-meeting pipeline: read tracks, chunk, transcribe, (phase 2) diarize, echo, merge, write, transcode, publish |
| `Meetings/DiarizerModelStore.swift` (phase 2) | Download and pin the FluidAudio model archive, modelled on `ModelStore` |
| `Meetings/Diarizer.swift` (phase 2) | FluidAudio offline pipeline behind two functions |
| `Meetings/VoicePrint.swift` (phase 3) | The user's centroid; matching |
| `Meetings/Roster.swift` (phase 3) | Names from the accessibility tree or the screen |
| `SettingsUI/MeetingsTab.swift` | The tab |
| `TypeMeItTests/Meetings/*Tests.swift` | One test file per pure type (section 12) |

### 5.2 Changes to existing files

| File | Change |
| --- | --- |
| `Transcriber.swift` | A second session on the same model with its own abort flag, for meeting chunks (7.10); `Error.status` carries the raw `transcribe_status` beside its message; `Word` becomes `Codable` |
| `SecureInput.swift` | `systemAudioSettingsURL` beside `accessibilitySettingsURL` (7.7) |
| `AudioCapture.swift` | `deviceID(forUID:)` becomes internal (7.5) |
| `Pipeline.swift` | Skip `OutputMute`, `MediaPause` and cues while a meeting records (D12); report dictation host-time spans to the coordinator; route the room shortcut |
| `Shortcuts.swift` | A second user combo, `recordRoomShortcut`, matched while idle (phase 2) |
| `Overlay/OverlayModel.swift`, `PillView.swift`, `OverlayPanel.swift` | The states in 7.7; closures `onRecordMeeting`, `onDeclineMeeting`, `onStopMeeting`, `onShowMeeting`, `onOpenSystemAudio`, `onUndoNeverAsk`; `showMeeting(_:)` with the `pendingMeeting` slot so a dictation loses neither a prompt nor a toast; `sharingType` per state |
| `TypeMeItApp.swift` | Menu items (7.11); `AppState.meeting`; `applicationShouldTerminate` |
| `MenuBarIcon.swift` | `puff(…, meeting:)`: a dot at the bottom left in `recordingTint`, cut out like the update dot |
| `Updates.swift` | `installWhenIdle` also waits for `MeetingCoordinator.shared.isIdle` |
| `Settings.swift` | Settings and `Fixed` constants in 7.8 |
| `SettingsUI/SettingsView.swift` | `SettingsTab.meetings` after `.history`, icon `akar-people-group`; a `meetings` group in the main settings tab |
| `Resources/Assets.xcassets` | `akar-people-group.imageset` (akar-icons, MIT), same `Contents.json` shape as `akar-history` |
| `Support/Info.plist` and `project.yml` | `NSAudioCaptureUsageDescription`; the folder keys in 7.12 |
| `RecordingArchive.swift` | `RecordingPlayer.toggle(id:urls:)`: one `AVAudioPlayer` per URL, all started with `play(atTime:)` at the same `deviceCurrentTime + 0.1` so a call's two tracks stay aligned; `stop` stops them all; `HistoryTab` calls it with one URL |
| `MediaPause.swift` | `playingProcesses()` becomes a filter over `AudioProcesses.snapshot()` |
| `Log.swift` | `Log.meetings` |
| `Store.swift` | `deleteAllHistory()` also deletes the voice print (phase 3) |
| `Makefile` | `diarizer-model`, `diarizer-model-verify`, `diarizer-model-publish`, `diarizer-model-verify-url` (phase 2) |
| `project.yml` | FluidAudio package (phase 2) |

### 5.3 Ownership and threads

- The aggregate's IO proc runs on a private serial dispatch queue that
  CoreAudio calls into. It copies into the two rings and returns. A
  `.utility` drain queue wakes every `Fixed.meetingDrainMs` (100 ms),
  converts each ring's new frames to 16 kHz mono Float32 with that track's
  own `AVAudioConverter`, hands them to the `TrackWriter` (own serial queue,
  which clamps, converts to Int16 and appends), and computes levels.
- CoreAudio property listeners run on their own serial queue. They post
  snapshots to the main actor with `Task { @MainActor in … }`.
- `MeetingCoordinator`, `MeetingStore`, `Settings`, `Pipeline` and
  `AppState` are `@MainActor`. The coordinator is the only writer of the
  machine.
- `MeetingTranscriber` runs as one detached `Task` per meeting and calls the
  `Transcriber` actor once per chunk, so it is serialised with dictation by
  the actor. A dictation waits at most one chunk (S2 bounds it).
- Everything under `Meetings/` that touches CoreAudio is
  `final class … : @unchecked Sendable` with an `NSLock`, the pattern
  `AudioCapture` and `RecordingArchive` already use.

### 5.4 One clock

Both tracks come from one `AudioDeviceCreateIOProcIDWithBlock` on one
aggregate device, so sample `n` of `mic.caf` and sample `n` of `others.caf`
were captured at the same instant, and every word timestamp is meeting time
with no bookkeeping. Every gap (a device rebuild, a rejoin) is filled with
zeros from host timestamps so the invariant holds: sample index divided by
16,000 is seconds since the meeting started.

Dictation runs on its own `AVAudioEngine` as today. Its span in the meeting
is computed from host time: the recorder records the host time of its first
IO proc callback as frame 0 and converts with `AVAudioTime.seconds(forHostTime:)`;
`Pipeline` reports the host time at `capture.start` and `capture.stop`
(`mach_absolute_time()`). A few tens of milliseconds of error is irrelevant
for folding whole words out.

## 6. Spikes

Each spike is a launch argument on the dev app, writes to `DebugLog` and to
files under `Store.directory/Meetings/probe/`, and is deleted once its line
below is filled in. Order: S1's detection half (`-meetingProbe`) and S4 run
against origin/main with nothing else built. S1's capture half needs 7.5's
aggregate, `TrackWriter`'s CAF header and the `NSAudioCaptureUsageDescription`
key from 7.12 (without the key the dev app never prompts and the tap stays
silent), so it runs once those exist behind the dev launch argument in 7.1;
S2 needs `ChunkCutter` from 7.10 and 7.14's import for its hour of audio;
S3 needs S1's `others.caf`. Only 7.2 to
7.4, 7.7 and the tap in 7.5 wait for S1's result; the rest of phase 1 is
built first, in the order 7.1 gives. Each spike opens with what it needs.

### S1. Detection, capture and the grant on the two targets

Needs: nothing for `-meetingProbe`; 7.5, `TrackWriter` and the 7.12 plist
key for `-meetingProbeCapture`.

`-meetingProbe`: install listeners on `kAudioHardwarePropertyProcessObjectList`
and, per process object, on `kAudioProcessPropertyDevices` at input scope
and at output scope. On every fire and every 1 s, log the full snapshot:
pid, bundle id (or `-`), executable path, resolved owner, input, output,
and which selector fired. Run against: a Slack huddle; Meet in Chrome and in
Safari; a Slack mic test; a Slack voice message; YouTube in another Chrome
tab while Meet is open; Krisp or Loopback if available; FaceTime.

`-meetingProbeCapture <bundle id> <seconds>`: resolve the app, build the
aggregate in 7.5 with the mic as a sub-device and a mono mixdown tap on all
of the app's process objects, write `mic.caf` and `others.caf` for that long,
log the tap format, the aggregate format, peak per second per track, and the
host time of the first callback. Then: set `kAudioTapPropertyDescription`
with one process removed and log whether audio kept flowing; try a second
tap described by `bundleIDs` and log whether it carries the helper's audio.
Play a click through the speakers while a far-end participant plays one and
measure the offset between the tracks in an editor. Run once on the built-in
mic and speakers, once on AirPods, once on a USB mic with headphones. Switch
the output device mid-run and log what the IO proc does. `kill -9` the app
mid-run and open both files with `AVAudioFile`.

Deny the grant first, and record what the tap delivered. Grant it from the
prompt and record whether audio arrived without a relaunch. Revoke it in
System Settings while running, re-grant, and record what macOS said.

On AirPods as both default input and output, in a Slack huddle, run the
capture twice — headset mic in the aggregate, then built-in — and ask the
far end whether either run was audible to them. Log any `-10868`, route
change or IO proc stall. This decides 7.5's call-on-Bluetooth rule.

Record in this file:

- Which process object carries input and which carries output for Slack and
  Chrome, and whether the resolver in 7.2 named the right app.
- Whether `Devices` listeners fire for input acquisition on an existing
  process object; the latency; whether the 1 s poll caught anything they
  did not.
- Whether the mic-plus-tap aggregate works on all three device sets, the
  measured inter-track offset (expected 0), and whether a device switch
  killed the IO proc.
- Whether the description update and `bundleIDs` work.
- Whether the killed files open and report the right duration.
- The grant's behaviour in all three paths and whether the
  `Privacy_AudioCapture` anchor opens the right pane.

Pass: both targets resolve to Slack and Chrome (or Safari); the tap carries
the far end; both tracks are aligned within 5 ms; the mic test and voice
message never show input and output together for 12 s; killed files open.
Any failure changes the matching section of this file before phase 1 starts.

### S2. Long tracks through Parakeet

Needs: `ChunkCutter` (7.10) and a CAF from S1's mic track or from the dev
mic recording (7.1).

`-transcribeFile <path>`: open the CAF, run three ways and log wall time and
peak resident memory for each: one offline `transcribe_run` over the whole
file; offline in 120 s chunks cut by `ChunkCutter` with a 2 s overlap; the
streaming API over the whole file. Log word counts and diff the three texts.
Score chunked against whole-file on a 30-minute single-speaker recording.
Log the longest single chunk time; that is how long a dictation can wait
behind a meeting.

Inputs: a 5-minute and a 60-minute recording of one speaker from S1's mic
track. Run on the fastest Mac to hand and the slowest.

Pass: chunked offline finishes an hour in under 90 s on the fast machine,
peak memory under 1.5 GB above the resident model, and the chunked text
differs from the whole-file text by under 0.2 percentage points of WER. If
whole-file also passes, drop the cutter. If neither passes, streaming
becomes the default. Write the chunk length and the longest chunk time into
`Fixed`.

### S3. FluidAudio in this project

Needs: S1's `others.caf` from a three-person call, ten kept dictation
recordings, and a five-minute room recording on the built-in mic with the
user speaking (7.1's `-recordRoom`).

Add the package pinned to the latest release, build with `xcodebuild`, and
note whether the module-map collision appears. Stage the offline pipeline's
model files in the layout 8.2 gives, turn networking off, and confirm the
load path in 8.2 (`offlineMode`, `OfflineDiarizerModels.load`, never
`prepareModels`) loads and runs with no request. Then corrupt one
`.mlmodelc` and load again: it must fail with no request and leave the
directory in place.

`-diarizeFile <path>`: run the offline pipeline with `computeUnits:
.cpuAndNeuralEngine` on S1's `others.caf` from a three-person call at
`stepRatio` 0.2 and 0.1, log segments, speaker count, wall time, and the
`speakerDatabase` embedding per speaker.

Start from a shipping MIT app's `OfflineDiarizerConfig` rather than the
defaults; it runs the same pipeline and its reasons are written down. Measure
each against the defaults, do not adopt blind:

- `clusteringThreshold` 0.5 against the 0.6 default. Higher stops merging
  earlier and yields *more* speakers — the polarity 3.3 warns about, stated
  the same way there.
- `segmentationMinDurationOn` 1.0, up from 0.0. At the default the
  segmentation model emits sub-second blips for backchannels ("yeah",
  "right") inside a monologue, which split one sentence across three speaker
  lines once words are aligned. Pyannote's paper recommends ≥1.0; FluidAudio's
  source puts the cost at 1.4% DER, which buys a transcript a person can read.
- `segmentationMinDurationOff` 0.5, up from 0.0, so a breath mid-sentence
  does not end a turn.
- Leave `excludeOverlap` and `exclusiveSegments` at their defaults. The second
  is load-bearing for 8.3: non-overlapping output is what makes one word map
  to exactly one speaker.
- `withSpeakers(exactly:)` overrides VBx's automatic count. Without it VBx
  picks its own, and on a conversation one person dominates it tends to pick
  **1** — the failure that merges the quiet participant into the loud one.
  Measure whether passing the count (phase 3's roster, or "far end + 1" on a
  1:1) is what fixes the three-speaker test. Then run the same pipeline over ten
kept dictation recordings (one speaker each) and log the cosine distance of
each embedding to the others and to the diarized speakers.

Pass: the offline load makes no request and the corrupted load deletes
nothing; three speakers found on the call; the hour-long call (S1's, or its
five-minute one timed and scaled linearly, saying so) diarizes in under two
minutes at whichever `stepRatio` the owner picks from the numbers; the
centroid of nine of the user's dictation embeddings is within 0.40 of the
tenth and at least 0.10 nearer to it than to any far-end speaker, and the
same holds for the user's embedding from the room recording. This is 9.1's
rule, so a pass validates the shipped matcher. If the distance test fails,
phase 3's voice print is dropped and rooms keep numbers only.

### S4. Rosters in the accessibility tree (before phase 3)

Needs: nothing built.

`-meetingProbeAX <bundle id>`: for Slack set `AXManualAccessibility` on the
app element; for Chrome set `AXEnhancedUserInterface` and wait 3 s. Dump the
tree under every `AXWebArea` once, then poll it every second for thirty
seconds while people speak. Do this on a Meet tab with the people panel
closed and open, and on a huddle collapsed and expanded. Clear the attribute
afterwards.

Record: are participant names present as `AXTitle` or `AXDescription`, does
anything change with the active speaker, does the tree survive a tab switch,
and how much CPU the browser spent while the attribute was set.

Pass: names present with the panel closed on at least one target. Otherwise
phase 3 uses the screen (9.2) or nothing.

## 7. Phase 1: calls

### 7.1 Build order and the dev mic recording

Build first, in this order: 7.8 (settings and constants), 7.5 (capture, no
tap), 7.6 (the recorder), 7.9 (storage), 7.10 (transcription) and 7.11 (the
tab, the settings group, and the menu items that do not depend on
detection), driven by 7.14's import and a dev-only launch argument `-recordRoom <seconds>`
that records the mic through `MeetingCapture` for that long into a staged
folder and runs the whole end-of-meeting pipeline. That exercises every file
but the watch, the machine, the coordinator and the tap without a second
person. Then, once S1's capture half has run, build 7.2 (process objects),
7.3 (the watch), 7.4 (the machine) and 7.7 (consent and the coordinator),
and add the tap to 7.5. 7.12 and 7.13 close the phase. The launch argument
becomes the room recording in phase 2.

### 7.2 Process objects

`AudioProcesses` (enum):

```swift
struct AudioProcessInfo: Equatable, Sendable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?        // nil when CoreAudio returns an empty string
    let path: String?            // proc_pidpath
    let input: Bool
    let output: Bool
}
static func snapshot() -> [AudioProcessInfo]   // MediaPause.playingProcesses, generalised
/// Fires `onChange` on `queue` when the process list changes or any process's
/// Devices property fires at input or output scope. Re-registers per-process
/// listeners when the list changes.
final class Listener { init(queue: DispatchQueue, onChange: @Sendable (_ why: String) -> Void) }
```

`MediaPause.playingProcesses()` becomes
`AudioProcesses.snapshot().filter { $0.output && !ProcessOwner.isOurs($0) }`
so the property-reading code exists once.

`ProcessOwner` (enum, pure, injected with the running apps):

```swift
struct Owner: Hashable, Sendable {
    let bundleID: String     // the owning app's, or the process's own for a daemon
    let name: String         // "Slack", "Google Chrome", "FaceTime"
    let appURL: URL?         // the app bundle, nil for a daemon
}
struct RunningApp: Equatable, Sendable { let bundleID: String; let name: String; let url: URL? }
/// Resolution, in order:
/// 1. `bundleID` non-empty: the running app whose bundle id equals it or is a
///    prefix of it followed by "." ("com.google.Chrome.helper" → Chrome).
///    No running app: a daemon; name from `Fixed.meetingDaemonNames`
///    ("com.apple.avconferenced" → "FaceTime"), else the last bundle-id
///    component. "com.apple.WebKit.GPU" is shared by every WKWebView app,
///    Safari included, so it resolves to Owner(bundleID: "com.apple.WebKit.GPU",
///    name: "web content", appURL: nil), and never-ask is not offered for it:
///    one cross would silence every web app.
/// 2. `bundleID` empty: the outermost ".app" in `path` → its running app;
///    else the executable name.
static func owner(of info: AudioProcessInfo, apps: [RunningApp]) -> Owner?
/// Our pid, or a bundle id starting with "it.typeme.typemeit" (release and dev).
static func isOurs(_ info: AudioProcessInfo) -> Bool
/// Apple daemons that hold the mic for the system: Fixed.meetingIgnoredBundleIDs.
static func isIgnored(_ info: AudioProcessInfo) -> Bool
```

`Fixed.meetingIgnoredBundleIDs`: `com.apple.CoreSpeech`, `com.apple.assistantd`,
`com.apple.universalaccessd`, `com.apple.accessibility.heard`,
`com.apple.systemsoundserverd`. `com.apple.avconferenced` is deliberately not
ignored. Add to the list only from a debug log that shows a false prompt.

Tests (`ProcessOwnerTests`): Chrome helper bundle id with Chrome running;
Slack helper; a plain app; `com.apple.avconferenced` with no app → FaceTime;
`com.apple.WebKit.GPU` → `web content`; empty bundle id with `/usr/bin/afplay` →
executable name; a path with `.app` twice (outermost wins); `isOurs` for
`it.typeme.typemeit` and `it.typeme.typemeit.dev`; `isIgnored`.

### 7.3 The watch

`MeetingWatch` (`@MainActor final class`, `@Observable`):

```swift
struct Holder: Equatable, Sendable {
    let owner: ProcessOwner.Owner
    let objectIDs: [AudioObjectID]   // every process object resolved to this owner
    let input: Bool                  // any of them
    let output: Bool                 // any of them
}
private(set) var holders: [Holder]   // every non-ours, non-ignored owner with input or output
var onChange: ((_ holders: [Holder]) -> Void)?
func start(); func stop()
```

Snapshots are taken on the listener's queue on every listener fire and every
`Fixed.meetingWatchPollSeconds` (1 s), grouped by owner, and delivered on the
main actor only when the grouped result changed, debounced
`Fixed.meetingWatchDebounce` (250 ms). Snapshot, group and compare are pure
functions over `[AudioProcessInfo]` and `[RunningApp]` so the transport
(listener or poll) is not load-bearing. The poll stays; S1 says how much the
listeners add.

### 7.4 The machine

`MeetingMachine` (struct, pure, `Equatable`):

```swift
enum State: Equatable {
    case idle
    case candidate(owner: Owner, since: Instant, bothSince: Instant?)   // input on; bothSince set when output joined, nil when it dropped
    case prompting(owner: Owner, since: Instant)         // asking; pill and menu item
    case declined(owner: Owner)                          // not this call
    case recording(owner: Owner?, since: Instant)        // owner nil for the room
    case paused(owner: Owner, since: Instant, before: Before)   // input released; waiting for a rejoin
    case finishing(owner: Owner?)
}
enum Before { case prompting, declined, recording }
enum Event {
    case holders([Holder])            // from the watch
    case tick(Instant)                // every second
    case record(Owner)                // the user; the owner the pill or the menu named
    case decline, stop, room          // the user
    case bothSilent                   // from the coordinator's silence deadline (7.6)
    case willSleep, didWake
    case recorderEnded(recordedMs: Int)
}
enum Effect: Equatable {
    case showPrompt(Owner), hidePrompt, showResumed(Owner)
    case startRecording(Owner?), pauseRecording, resumeRecording, stopRecording
    case finished(keep: Bool)
}
struct Rules { var confirm, armTimeout, resume, rejoin, minimum, sessionCap: Duration; var neverAsk: Set<String> }
mutating func handle(_ event: Event, now: Instant, rules: Rules) -> [Effect]
```

The coordinator builds `Rules` from `Fixed` (`meetingConfirmSeconds`,
`meetingArmTimeoutSeconds`, `meetingResumeSeconds`, `meetingRejoinSeconds`,
`meetingMinimumSeconds`, `meetingSessionCapSeconds`) and
`Settings.meetingNeverAsk`. `minimum` is compared as
`Duration.milliseconds(recordedMs) >= rules.minimum`.

Edge, not level: the machine keeps the set of owners that held input at the
last `holders` event. A new candidate needs an owner whose input went from
off to on. The first `holders` after `start`, after `didWake`, and after a
device-configuration change only seeds that set. An app already holding the
mic when the app launches, or an always-on mic filter, never prompts; the
menu item (7.11) still offers to record it by hand.

Transitions:

| From | On | To | Effects |
| --- | --- | --- | --- |
| idle | an owner's input turns on, not on `neverAsk` | candidate(owner, now, nil) | beginPreRoll(owner) |
| idle | record(owner) | recording(owner, now) | startRecording(owner) |
| idle | room | recording(nil, now) | startRecording(nil) |
| candidate(bothSince: nil) | owner output on | candidate(owner, since, now) | |
| candidate | owner output off | candidate(owner, since, nil) | |
| candidate | now − bothSince ≥ confirm | prompting(owner, now) | showPrompt |
| candidate | owner input off | idle | discardPreRoll |
| candidate | now − since ≥ armTimeout with output never on | idle (no re-arm until input drops) | discardPreRoll |
| candidate | record(owner) | recording(owner, now) | startRecording(owner), promoting the pre-roll |
| prompting | record(owner) | recording(owner, now) | hidePrompt, startRecording(owner), promoting the pre-roll |
| prompting | decline | declined(owner) | hidePrompt, discardPreRoll |
| prompting | owner input off | paused(owner, now, .prompting) | hidePrompt, discardPreRoll |
| declined | record(owner) | recording(owner, now) | startRecording(owner) |
| declined | owner input off | paused(owner, now, .declined) | |
| recording(owner) | owner input off | paused(owner, now, .recording) | pauseRecording |
| recording(owner) | bothSilent | finishing(owner) | stopRecording |
| recording(nil) | bothSilent | finishing(nil) | stopRecording |
| recording(nil) | an owner's input turns on | (unchanged: no candidate, no prompt; 8.1) | |
| recording | room | (unchanged) | |
| recording(owner) | stop | finishing(owner) | stopRecording |
| recording(owner) | now − since ≥ sessionCap | finishing(owner) | stopRecording |
| paused(.recording) | owner input on within resume | recording(owner, since) | resumeRecording, showResumed(owner) |
| paused(.recording) | now − since ≥ resume | finishing(owner) | stopRecording |
| paused(.prompting) | owner input on within rejoin | prompting(owner, now) | showPrompt |
| paused(.declined) | owner input on within rejoin | declined(owner) | (no prompt) |
| paused(.prompting or .declined) | record(owner) | recording(owner, now) | startRecording(owner) |
| paused(.prompting or .declined) | now − since ≥ rejoin | idle | |
| any but idle | willSleep | finishing(owner) if recording or paused(.recording), else idle | stopRecording if recording |
| any | didWake | (unchanged) | re-seed on the next holders |
| finishing(owner) | recorderEnded(ms) | idle | finished(keep: owner == nil or ms ≥ minimum) |

Several candidates: the one with both flags, else the earliest. A different
owner while prompting restarts at candidate. `record(owner)` from the menu
carries the owner `detected` names at click time (both flags, else the
earliest); from the pill it carries the prompting owner, and a mismatch is
ignored. The coordinator resolves that owner's process objects from the
current `MeetingWatch` holders before it applies `startRecording`. A cross
survives a drop and rejoin inside `rejoin`; an unanswered prompt comes back
as a prompt; a recording survives a drop inside `resume`, and `showResumed`
tells the user.

Tests (`MeetingMachineTests`) walk every row with an injected clock, plus:
input only for 90 s never prompts (mic test); input and output for 11 s then
off never prompts; input and output at 12 s prompts; decline, input off
30 s, input on → still declined, no second prompt; record, off 20 s, on →
one recording with one pause, one resume and one `showResumed`; record, off
31 s → finishing; an owner already holding input at the first event never
becomes a candidate, but `record(owner)` from idle starts a recording named
for it; `record` after a decline starts a recording; prompting, input off
5 s, input on, `record` → a recording; output on at 11 s, off, on again at
13 s → prompts at 25 s, not 12 s; prompting, input off 10 s, input on →
prompts again; `bothSilent` while recording finishes it; `room` while a call records changes
nothing; an owner's input turning on while the room records changes nothing;
a room recording of 20 s is kept; a call of 89 s is dropped and of 91 s
kept; willSleep while recording finishes it; sessionCap fires.

### 7.5 Capture

`AudioRing` (struct over an `UnsafeMutableBufferPointer<Float>`, SPSC):
`init(capacity:)`, `write(_:count:)` from the producer, `read(into:)` from
the consumer, both lock-free with atomic indices. Capacity
`Fixed.meetingRingSeconds` (4 s) at the device rate. Tests: wrap, overrun
(drops and counts).

`MeetingCapture` (`final class`, `@unchecked Sendable`):

```swift
struct Device { let uid: String; let name: String }
init(mic: Device, tapProcesses: [AudioObjectID]?, sink: Sink) throws
protocol Sink: AnyObject {
    /// Called on the drain queue with 16 kHz mono Float32, one call per track per drain.
    func capture(_ capture: MeetingCapture, mic: [Float], others: [Float]?)
    func captureRebuilt(_ capture: MeetingCapture, gapFrames: Int)
    func captureFailed(_ capture: MeetingCapture, error: Error)
}
func updateTap(processes: [AudioObjectID]) throws   // kAudioTapPropertyDescription; rebuild if refused
func stop()
var firstHostTime: UInt64 { get }                    // of the first IO proc callback
var micFormat: AudioStreamBasicDescription { get }
var tapFormat: AudioStreamBasicDescription? { get }
```

Geometry:

- Mic device: `Settings.microphoneUID` resolved with `AudioCapture.deviceID(forUID:)`
  (today `private`; make it internal), else the default input device —
  except for Bluetooth, read from `kAudioDevicePropertyTransportType`
  (`kAudioDeviceTransportTypeBluetooth`, `…BluetoothLE`):
  - **A room never records a Bluetooth mic unless the user picked it.** With
    no explicit `microphoneUID` and a Bluetooth default input, use the
    built-in mic. An earbud is the wrong microphone for a room, and opening
    it moves the headset from its music profile to its call profile, so
    whatever the user is listening to drops to call quality for the length
    of the meeting.
  - **A call records the headset mic, pending S1.** The call app already
    holds it (that is what made the candidate), so the headset is already
    in its call profile and we change nothing the user can hear; and a mic
    in the ear is the cleanest `You` track there is. A shipping Parakeet
    notetaker defaults the other way — built-in whenever a Bluetooth headset
    is both input and output — after contention with the call app's own
    use of the headset. S1 runs that case on purpose; if the aggregate
    glitches, fails to start or flips the route, the call takes the built-in
    mic too and the row says so.
  - Chosen once at start and pinned. A device rebuild (below) may fall back
    to built-in once after a real Bluetooth outage; it never follows a
    changing default for the rest of the meeting.
  - Nothing ever writes the Mac-wide default input device. The aggregate
    binds the device it wants; writing and restoring the default is how the
    same app got route flip-flops, a slower start, and audible glitches.
- Tap: `CATapDescription(monoMixdownOfProcesses: processes)` with a fresh
  UUID, `muteBehavior` left at its unmuted default, `privateTap = true`,
  `processRestoreEnabled = true`. Absent for the room.
- Aggregate: `kAudioAggregateDeviceUIDKey` a fresh UUID,
  `kAudioAggregateDeviceIsPrivateKey: true`, `kAudioAggregateDeviceIsStackedKey: false`,
  and no `kAudioAggregateDeviceTapAutoStartKey` (section 13).
  `kAudioAggregateDeviceMainSubDeviceKey` (the clock): the default output
  device's UID when there is a tap, else the mic's.
  `kAudioAggregateDeviceSubDeviceListKey`: an array of dictionaries keyed by
  `kAudioSubDeviceUIDKey`, one for the main device and one for the mic with
  `kAudioSubDeviceDriftCompensationKey: 1` when it is not the main device
  (one entry when the same device serves both, as AirPods do).
  `kAudioAggregateDeviceTapListKey`: one dictionary with `kAudioSubTapUIDKey`
  (the tap's UUID string) and `kAudioSubTapDriftCompensationKey: 1`.
- One `AudioDeviceCreateIOProcIDWithBlock` on the aggregate, queue
  `it.typeme.typemeit.meeting-io`. The block copies the mic channel and the
  tap channel out of the input buffer list into the two rings and returns.
  Which input channels belong to which sub-device comes from the aggregate's
  stream layout, read once after creation.
- The drain queue converts each ring with an `AVAudioConverter` built from
  that stream's format (mic and tap formats differ), zero-fills any gap the
  host timestamps show, and calls the sink.
- Listeners on `kAudioHardwarePropertyDefaultOutputDevice`,
  `kAudioHardwarePropertyDefaultInputDevice` (when the mic is the default)
  and `kAudioHardwarePropertyDevices`: when a member device disappears or
  the default changes, tear down (order in 3.2), rebuild with the new device,
  and report the gap in frames so the writers fill it. Bounded retry:
  `Fixed.meetingRebuildAttempts` (3), `Fixed.meetingRebuildIntervalSeconds`
  (1) apart, then `captureFailed`.
- Teardown in the order 3.2 gives, with a barrier onto the drain queue
  before destroying the aggregate.

`TrackWriter` (`final class`, own serial queue):

```swift
init(url: URL) throws            // writes the 68-byte CAF header below
func append(_ pcm: [Float])      // clamps to ±1, converts to Int16 LE, appends
func appendSilence(frames: Int)
func finish() -> (frames: Int, peak: Float)
var framesWritten: Int { get }
/// Peak over the most recent Fixed.meetingSilentSeconds of audio.
var recentPeak: Float { get }
```

The file is a CAF whose `data` chunk size is `-1`, which the CAF format
defines as "unknown, runs to the end of the file", so a `kill -9` at any
point leaves a file `AVAudioFile` opens. Written once, never patched,
big-endian:

| Bytes | Field | Value |
| --- | --- | --- |
| 4 | file type | `caff` |
| 2, 2 | version, flags | 1, 0 |
| 4, 8 | chunk type, size | `desc`, 32 |
| 8 | sample rate | 16000.0 (Float64) |
| 4 | format id | `lpcm` |
| 4 | format flags | 2 (little-endian, integer) |
| 4, 4, 4, 4 | bytes per packet, frames per packet, channels, bits | 2, 1, 1, 16 |
| 4, 8 | chunk type, size | `data`, −1 |
| 4 | edit count | 0 |

Then Int16 little-endian frames. Test (`TrackWriterTests`): a written file
truncated at an arbitrary byte opens with `AVAudioFile` and reports
`(bytes − 68) / 2` frames.

### 7.6 The recorder

`MeetingRecorder` (`final class`, `@unchecked Sendable`, owned by the coordinator):

```swift
enum Kind { case call(Owner, processes: [AudioObjectID]), room }
init(kind: Kind, folder: URL, mic: MeetingCapture.Device) throws
func updateTap(processes: [AudioObjectID])
func pause()          // writers switch to silence; the sink discards
func resume()
func noteDictation(startHostTime: UInt64, endHostTime: UInt64, historyId: UUID)
func stop() async -> Result   // frames and peak per track, gaps, dictation spans, bothSilentSeconds
var onSilenceChanged: (@Sendable (Bool) -> Void)?   // true once every track (both for a call, the one for a room) has stayed at the floor for meetingSilentSeconds; false when signal returns
var onLevels: (@Sendable (_ mic: Float, _ others: Float?) -> Void)?   // 10 Hz, for the tab's meters
```

- On `init`: create the staged folder (7.9), write `meeting.json` with
  `transcription.state = pending` and `ended = null`, open `mic.caf` (and
  `others.caf` for a call), start the capture. Frame 0 of both files is the
  capture's first callback; `firstHostTime` is stored in `meeting.json`.
- Silence. The recorder fires `onSilenceChanged(true)` when every track's
  `recentPeak` has stayed below `Fixed.meetingSilenceFloor` (−60 dBFS, 0.001)
  for `Fixed.meetingSilentSeconds` (90 s; both tracks for a call, the one
  track for a room), and `false` when signal returns. The coordinator, on
  `true`: for a call, show `.meetingSystemAudioOff` the first time; for
  either kind, arm a deadline of `Fixed.meetingBothSilentEndSeconds` (600 s)
  minus `meetingSilentSeconds` on its tick, cancelled by `false`, that sends
  `bothSilent` to the machine when it fires. A room shows no pill, since
  there is no tap to blame. A far end at the floor while the mic is alive
  means everyone else is muted, and nothing is said.
- Sleep. Hold `kIOPMAssertionTypePreventUserIdleSystemSleep` (never the
  display variant: the screen should still dim and lock) from the first
  capture callback to `stop()`, named "type me it is recording a meeting".
  Taken on the first callback rather than on `init` so a denied grant does
  not hold the machine awake for nothing, and held by our own process, so
  the OS releases it on every exit path including `_exit(0)` and `kill -9`.
  This matters for a room, not a call: a call's own app already holds an
  assertion, but a Mac recording a meeting from the table with nobody
  touching it idles to sleep mid-sentence. `willSleep` then means the lid
  closed or the user chose Sleep, which is still a finish (7.4).
- Gaps: `pause()` records the frame index; `resume()` records the end. Both
  tracks receive zeros for the gap. A capture rebuild reports its gap the
  same way. Every gap goes into `tracks[].gaps`.
- Dictation: spans are converted from host time to frames using
  `firstHostTime` and stored as `dictations[]`.
- `stop()` stops the capture, finishes the writers and returns. Tracks under
  `Fixed.meetingMinimumSeconds` for a call are deleted with the folder
  (`finished(keep: false)`).

### 7.7 Consent and the coordinator

`MeetingCoordinator` (`@MainActor @Observable final class`, `shared`, started
from `Pipeline.start()`):

- Feeds `MeetingWatch.onChange`, a 1 s tick, `NSWorkspace.willSleepNotification`
  and `didWakeNotification` into the machine and applies the effects.
- `showPrompt`: `OverlayPanel.showMeeting(.meetingPrompt(app:))`. Every
  meeting state goes through `showMeeting(_:)`, never through
  `Pipeline.showToast`, whose idle guard would drop a toast during a
  dictation. While the cloud is up, `showMeeting` parks the state in
  `OverlayModel.pendingMeeting`, and `hide()`'s completion shows it when the
  cloud leaves. `hidePrompt` clears both the shown prompt and the parked one.
- `showResumed`: `.meetingResumed(app:)`, whose `stop` sends `stop` to the
  machine. It is a toast, not a question: the recording has already resumed.

**Pre-roll (D20).** Consent arrives `meetingConfirmSeconds` (12 s) plus a
human's reaction time after the meeting started, and that is the part of a
meeting that says what it is about. So the coordinator starts capturing at
`candidate`, into memory, and only writes on `record`:

- `PreRoll` holds one `AudioRing` per track sized `Fixed.meetingPreRollSeconds`
  (120) at 16 kHz mono Float32: 7.7 MB a track, 15.4 MB for a call. It
  overwrites oldest-first and never allocates after `init`.
- `candidate` gains the effect `beginPreRoll(owner)`: build a `MeetingCapture`
  exactly as `startRecording` would, with a sink that writes into the rings
  instead of the writers. Two things can fail softly — without the tap grant
  the far-end ring is absent and the mic is still buffered; a capture that
  throws leaves `preRoll = nil` and the meeting simply starts at the click.
- `record` hands the live capture to `MeetingRecorder` rather than building a
  second one, so there is no gap at the seam. The recorder opens the tracks,
  writes each ring's contents first through the same `TrackWriter`, then
  continues live. Frame 0 is the oldest pre-roll frame and `firstHostTime` is
  that frame's host time, so 5.4's clock, `dictations[]` and the gap
  bookkeeping all keep working unchanged. `preRollMs` goes in `meeting.json`.
- `decline`, `neverAsk`, the candidate lapsing at `armTimeout`, input
  dropping, and `stopForQuit` all call `discard()`, which zeroes the buffers
  before freeing them. Nothing reaches a file, and no buffer outlives the
  candidate that made it.
- A room is started by hand and has no candidate, so it has no pre-roll.
  There is no always-on buffer: the app holds audio only while another app
  is in a call with the mic and the output both live.
- `Settings.meetingPreRoll`, default on, and `Settings.meetingAsk == false`
  suppresses the pre-roll with the prompt.
- Tests (`PreRollTests`): a ring that wrapped yields the newest 120 s
  oldest-first; consent after 30 s yields 30 s; `discard` leaves nothing
  readable; a mic-only pre-roll on a call promotes with the far-end track
  starting at the seam and its pre-roll span zero-filled.

The honest cost: the microphone opens before the user has agreed to anything,
which macOS shows in the menu bar and in Control Center. That is the right
way round — the indicator is true — but it is a change in what the app does
while idle, so the settings row says it plainly (section 11) and turning the
prompt off turns it off.
- Exposes `detected: Owner?` (level: any holder with input and output, for
  the menu), `prompting: Owner?`, `recording: (kind, started)?`,
  `levels: (mic: Float, others: Float?)` (from `MeetingRecorder.onLevels`,
  10 Hz), `transcribing: (id, fraction)?`, `isIdle`. The tab's status row,
  its meters and `MenuContent` read this live state here; `MeetingStore`
  holds the list. `AppState.meeting` mirrors `recording != nil`.
- `Settings.meetingAsk == false`: the machine still runs (so the menu works)
  but `showPrompt` does nothing.
- Never-ask: the menu item `Don't Ask for <app> Again` appends the owner's
  bundle id to `Settings.meetingNeverAsk` and shows `.meetingNeverAsking(app:)`
  with `undo`.
- Dictation: `Pipeline` calls `coordinator.dictationBegan(hostTime:)` and
  `dictationEnded(hostTime:historyId:)`; while `recording != nil`,
  `Pipeline.beginRecording` skips `OutputMute.mute()`, `MediaPause.pause()`
  and `playWhileMuted`, and `endRecording` skips the stop cue.
- Quit: `AppDelegate.applicationShouldTerminate` calls
  `coordinator.stopForQuit()`, which sends `stop`, waits for the writers to
  finish (bounded by `Fixed.meetingQuitWaitSeconds`, 2 s), and then returns
  `.terminateNow`. The existing
  `_exit(0)` in `applicationWillTerminate` runs after.
- Updates: `Updates.installWhenIdle` also requires `coordinator.isIdle`.

Pill states (`OverlayModel.State`, all `.pill`):

| State | Left | Label | Right | Lifetime |
| --- | --- | --- | --- | --- |
| `.meetingPrompt(app: Owner)` | app icon (`NSWorkspace.shared.icon(forFile:)`, or the generic app icon) | `record this meeting?` | `record` (primary), cross (help `Not now`) | until answered or `hidePrompt` |
| `.meetingNeverAsking(app: Owner)` | app icon | `won't ask for slack again` | `undo`, cross | toast timer |
| `.meetingSystemAudioOff` | `akar-microphone` | `system audio is off` | `system settings` (primary), cross | toast timer |
| `.meetingSaved(id: UUID)` | `akar-people-group` | `meeting saved` | `show` (primary), cross | toast timer |
| `.meetingFailed(id: UUID)` | `akar-people-group` | `meeting not transcribed` | `show`, cross | toast timer |
| `.meetingDiskFull` | `akar-people-group` | `disk full · meeting stopped` | `show`, cross | until dismissed |
| `.meetingResumed(app: Owner)` | app icon | `recording again · slack` | `stop` (primary), cross | toast timer |
| `.meetingFolderUnavailable` | `akar-people-group` | `meetings folder unavailable` | `settings` (primary), cross | toast timer |

`OverlayPanel` sets `panel.sharingType = .none` while any meeting state is
shown and `.readOnly` otherwise, so the prompt is not drawn into a display
share; `NSWindow` warns that `.none` windows lose some system services, so
it is scoped to these states. `show`, and the folder toast's `settings`, set `AppState.shared.settingsTab = .meetings`
and opens the window like the learned toast's sparkle does. `system settings`
opens `SecureInput.systemAudioSettingsURL`
(`x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture`,
verified in S1).

### 7.8 Settings and constants

`Settings`:

| Key | Type | Default | Where |
| --- | --- | --- | --- |
| `meetingAsk` | Bool | true | main tab, `meetings` group: `record meetings` picker `ask` / `never` |
| `meetingNeverAsk` | [String] bundle ids | [] | main tab: `never ask for` chips, hidden when empty |
| `meetingKeepAudio` | Bool | true | Meetings tab footer: `keep the audio` |
| `meetingLimit` | Int | 0 (everything) | Meetings tab footer: `keep` picker like History's |
| `meetingsMCP` | Bool | false | Meetings tab footer: `mcp` (7.15) |
| `meetingsFolder` | URL? | nil (= `Store.directory/Meetings`) | Meetings tab footer: `meetings folder` |
| `recordRoomShortcut` | KeyCombo? | nil | main tab, phase 2 |
| `voicePrintEnabled` | Bool | false | main tab, phase 3 |
| `rosterEnabled` | Bool | false | main tab, phase 3 |

`Fixed`, each with its source in a comment:

| Constant | Value | Source |
| --- | --- | --- |
| `meetingConfirmSeconds` | 12 | booleans, not audio; long enough to outlast a chime over a voice message |
| `meetingArmTimeoutSeconds` | 90 | atrium's confirm window, repurposed: input with no output is a mic test |
| `meetingRejoinSeconds` | 120 | atrium; how long a cross is remembered after the app drops the mic |
| `meetingResumeSeconds` | 30 | a dropped call rejoins in seconds; a different call in the same app inside 30 s is unlikely, and the pill covers it |
| `meetingMinimumSeconds` | 90 | atrium, applied to recorded audio |
| `meetingSessionCapSeconds` | 14 400 | an app that never releases the mic |
| `meetingSilentSeconds` | 90 | meeting-transcriber `SilentRecordingMonitor` |
| `meetingSilenceFloor` | 0.001 (−60 dBFS) | same |
| `meetingBothSilentEndSeconds` | 600 | an idle call; also a forgotten room recording |
| `meetingRebuildAttempts`, `meetingRebuildIntervalSeconds` | 3, 1 | one rebuild usually suffices; three a second apart cover a slow USB re-enumeration |
| `meetingMCPBudgetBytes` | 24 576 | one meeting's text in a reply without crowding a client's window (7.15) |
| `meetingPreRollSeconds` | 120 | longer than a prompt is ever left unanswered; 15.4 MB for a call (D20) |
| `meetingQuitWaitSeconds` | 2 | the writers flush in milliseconds; two seconds bounds a stuck disk |
| `meetingTitleSourceWords` | 700 | fits the 4,096-token window beside the instructions |
| `meetingRosterPollMinutes` (phase 3) | 5 | people join in the first minutes |
| `meetingWatchDebounce` | 250 ms | the list listener fires several times per launch |
| `meetingWatchPollSeconds` | 1 | the backstop the listeners need |
| `meetingRingSeconds` | 4 | chosen, not measured: forty drain periods of headroom; raise if `AudioRing` reports overruns |
| `meetingDrainMs` | 100 | chosen, not measured: 4,800 frames a drain at 48 kHz, and the tick the tab's meters read at 10 Hz |
| `meetingChunkSeconds` | 120 | S2 |
| `meetingChunkOverlapSeconds` | 2 | S2 |
| `meetingChunkSearchSeconds` | 5 | seam within ±5 s of the nominal cut |
| `meetingParagraphGapSeconds` | 2 | chosen, not measured: the pause between two thoughts; raise if paragraphs fragment |
| `meetingFolderNameMax` | 200 bytes | NAME_MAX is 255 bytes |
| `meetingMinimumFreeBytes` | 500 MB | two raw tracks are 230 MB an hour |
| `meetingAudioBitrate` | 32 000 | 7.9 |
| `meetingDaemonNames` | `[bundle id: name]` | 3.2 |
| `meetingIgnoredBundleIDs` | the set in 7.2 | 3.2 |
| `meetingDiarizerStepRatio` (phase 2) | S3 | FluidAudio: 0.2 default, 0.1 for meetings |
| `meetingVoicePrintTargetSamples`, `meetingVoicePrintMinimumSamples` (phase 3) | 50, 10 | chosen, not measured: ten dictations is a day of use; S3 revises both |
| `meetingVoicePrintMinimumClipSeconds` (phase 3) | 5 | FluidAudio's documented minimum for a usable embedding |
| `meetingVoicePrintDistance`, `meetingVoicePrintMargin` (phase 3) | 0.40, 0.10 until S3 | meeting-transcriber `SpeakerMatcher` |

Echo detector constants are the lifted file's own.

### 7.9 Storage

Staging: `Store.directory/Meetings/.in-progress/<uuid>/`, created at record
with `isExcludedFromBackup = true`. Published: `Settings.meetingsFolder ??
Store.directory.appendingPathComponent("Meetings")`. The folder moves from
staging to published as the last step of transcription. A published folder
picked outside `~/Library` needs the folder usage strings in `Info.plist`
(7.12) for the case where the app lists a folder it did not create (the
user renamed one in Finder); the open panel itself is the consent for the
folder the user picked.

Name: `MeetingFolder.name(started: Date, zone: TimeZone, duration: Duration?, title: String, existing: [String]) -> String`
(pure, tested; `existing` is the published folder's current names):

- `yyyy-MM-dd HHmm` in the meeting's time zone, then the duration when known
  (`8m`, `45m`, `1h20m`, rounded to the minute), then the title.
- Sanitise the title: replace `/` and `:` with `-`, drop control characters
  and newlines, collapse whitespace, trim, strip leading dots, precompose to
  NFC, cap the whole name at `Fixed.meetingFolderNameMax` bytes on a grapheme
  boundary. An empty title falls back to the app name, then `meeting`. `#`
  stays; every file URL is built with `URL(fileURLWithPath:)` or
  `appendingPathComponent`, never `URL(string:)`.
- Collision: compare case- and normalisation-folded against `existing`;
  append ` 2`, ` 3`.
- A user rename rewrites the title part only.

The folder name is a label. `meeting.json` carries the id; `MeetingStore`
resolves meetings by reading it, so a rename in Finder is just a move.

Files: `meeting.json`, `transcript.md`, `mic.m4a` and `others.m4a` (call) or
`room.m4a` (room). During recording and transcription the tracks are `.caf`;
they are transcoded to AAC by `MeetingFolder.transcode(from:to:)` reading and
writing through `AVAudioFile` 1 s at a time (`RecordingArchive.write` is
whole-array and stays for dictations), at `Fixed.meetingAudioBitrate`
(32 000; the dictation archive's 16 kbps is tuned for one close speaker, a
far-end mix gets twice that). The `.caf` is deleted only after the `.m4a`
reopens with a frame count within one buffer of the source *and* its last
second decodes. A header can claim the right length over a truncated tail. With
`Settings.meetingKeepAudio` off, the `.caf` files are deleted after
transcription and no `.m4a` is written.

`Meeting` (Codable, `schema: 1`), written with `Store`'s encoder settings
(`.iso8601`, `.sortedKeys`, `.prettyPrinted`) and `.atomic`:

```json
{
  "schema": 1,
  "id": "9F2C…",
  "kind": "call",
  "started": "2026-09-19T13:30:12Z",
  "timeZone": "Europe/London",
  "ended": "2026-09-19T14:04:48Z",
  "durationMs": 2076000,
  "recordedMs": 2014000,
  "firstHostTime": 123456789012,
  "app": { "bundleId": "com.tinyspeck.slackmacgap", "name": "Slack" },
  "title": "Slack",
  "titleSource": "app",
  "published": true,
  "tracks": [
    { "role": "mic", "file": "mic.m4a", "frames": 33216000, "gaps": [{ "startMs": 1840000, "endMs": 1902000 }] },
    { "role": "others", "file": "others.m4a", "frames": 33216000, "gaps": [{ "startMs": 1840000, "endMs": 1902000 }] }
  ],
  "audio": { "inputDevice": "MacBook Pro Microphone", "outputDevice": "MacBook Pro Speakers", "outputTransport": "bltn", "outputDataSource": "ispk" },
  "echo": "affected",
  "bothSilentMs": 0,
  "dictations": [{ "startMs": 923000, "endMs": 931000, "historyId": "…" }],
  "speakers": [
    { "id": "you", "name": "You", "isYou": true, "talkMs": 394000 },
    { "id": "them", "name": "Them", "isYou": false, "talkMs": 1413000 }
  ],
  "transcription": { "state": "done", "error": null, "asr": "parakeet-unified-en-0.6b-Q8_0", "diarizer": null, "tookMs": 41000, "done": { "mic": 18, "others": 18 } },
  "paragraphs": [
    { "speaker": "you", "startMs": 14000, "endMs": 21000, "text": "Morning. Shall we start with the deploy?" }
  ]
}
```

- `kind`: `call` or `room`. A room has no `app`, one track with role
  `room`, and speakers `s1…sN` in phase 2.
- `titleSource`: `app`, `user`, `generated`, `roster`.
- `published`: false until the folder has moved to the published folder; a
  meeting can be `done` and still unpublished (7.10, step 6).
- `echo`: `notMeasured`, `clean`, `affected` (7.10).
- `transcription.state`: `pending`, `running`, `done`, `failed`;
  `transcription.done` counts finished chunks per track so a run resumes.
- While recording, `ended` is null and the tracks name `.caf` files.
- Times in ms are meeting time (frame / 16). `frames` is `durationMs × 16`
  for every track, since gaps are zero-filled (5.4); `recordedMs` is
  `durationMs` minus the summed gaps. `Meeting.decode(_ data: Data) -> Meeting?`
  ignores unknown keys and returns nil, with a log line, for a `schema`
  above 1.
- `talkMs` and `speakers` include the user; `speakers.count` is what the row
  shows.

`TranscriptRender.markdown(_ meeting: Meeting) -> String` (pure,
snapshot-tested). Front matter is flat, every string quoted, written and
never read:

```markdown
---
title: "Slack"
kind: call
started: "2026-09-19 14:30 +01:00"
duration: 35m
app: "Slack"
speakers: ["You", "Them"]
echo: affected
---

**You** · 0:14
Morning. Shall we start with the deploy?

**Them** · 0:21
…
```

Times are `m:ss` from the start, or `h:mm:ss` past an hour. The file is
rewritten whenever `meeting.json` changes.

`MeetingStore` (`@MainActor @Observable final class`, `shared`):

- At launch, reads every `*/meeting.json` under the published folder and
  under staging; `meetings` sorted newest first, keyed by `id`. A
  `DispatchSource` on the published folder re-reads when it changes. When the
  published folder does not resolve (an ejected disk, an offline share) the
  store carries on with staging alone: `diskUsage` is nil, the footer row
  says `unavailable`, and the `DispatchSource` is attached when the folder
  next resolves.
- Republishing: every meeting with `state == done` and `published == false`
  is moved to the published folder at launch and whenever the coordinator's
  1 s tick finds the folder resolving again; success sets `published`.
- Launch recovery: a staged meeting with `ended == null` gets `ended` set
  from its `.caf` length (the app quit or crashed while recording), then
  every staged meeting in `pending` or `running` is queued for
  transcription, resuming at the first chunk not in `transcription.done`.
- `save(_:)` writes JSON atomically then renders the Markdown.
  `rename(id:title:)` sets `titleSource = user`, saves, moves the folder.
  `rename(speaker:to:in:)` (phase 2). `delete(ids:)` stops the player and
  moves folders to the Trash with `NSWorkspace.shared.recycle`. `deleteAll()`.
  `prune()` applies `meetingLimit` newest-first, recycling the rest and, like
  `deleteAll()`, stopping the player first when it is playing one of them.
  `diskUsage` sums the published folder.
- Holds the list only. Live state (`recording`, `transcribing`, `levels`) is
  the coordinator's (7.7); `downloadingDiarizer` (phase 2) is
  `DiarizerModelStore`'s.

### 7.10 Transcription

`Transcriber` gains a second session for meetings:

```swift
/// Runs on a second session of the same loaded model with its own abort
/// flag, so a dictation cancel never aborts a meeting chunk and vice versa.
/// The actor still runs one piece of compute at a time, as the library requires.
func transcribeMeetingChunk(_ pcm: [Float]) throws -> Transcript
nonisolated func cancelMeeting()
```

`ensureLoaded` creates the second session lazily from the same model;
`unload` frees both; `scheduleUnload` is skipped while a meeting chunk is
queued.

Types, all `Codable` and `Equatable`, in `Meeting.swift`:

```swift
struct TrackWords { let role: String; var words: [Transcriber.Word] }   // Transcriber.Word gains Codable
struct Span { let startMs: Int; let endMs: Int }
struct SpeakerSegment { let speaker: String; let startMs: Int; let endMs: Int }   // phase 2, from Diarizer
struct Paragraph { let speaker: String; let startMs: Int; let endMs: Int; let text: String }   // the JSON shape in 7.9
```

`ChunkStitch.append(_ new: [Transcriber.Word], after tail: [Transcriber.Word], overlapMs: Int) -> [Transcriber.Word]`
(pure) drops a word in the overlap that repeats one of the tail's by text
and by time within 300 ms. Tests (`ChunkStitchTests`): a repeated word is
dropped; a different word at the same time is kept; an empty tail; an
overlap with no words.

`ChunkCutter.cuts(peaks: [Float], frameMs: Int, maxChunkMs: Int, overlapMs: Int, searchMs: Int) -> [Range<Int>]`
(pure): given a 100 ms peak envelope, returns chunk ranges of at most
`maxChunkMs`, each seam placed at the quietest frame within ±`searchMs` of
the nominal boundary, consecutive chunks overlapping by `overlapMs`. Tests:
silence everywhere cuts at the maximum; one quiet frame in the search window
is chosen; a track shorter than one chunk returns one range; overlaps are
exact.

`EchoBleedDetector` is lifted from meeting-transcriber
(`app/MeetingTranscriber/Sources/EchoBleedDetector.swift`, MIT): its
constants, `WindowScore`, `Result` and `analyse` with its helpers; not the
`micDelay` input (the tracks share a clock, so the lag search is centred on
0) and not `EchoVerdict`, whose initialiser takes a type that repository
never defines. `analyse` is changed to take the two tracks' 10 ms RMS
envelopes (`[Float]`, 100 values a second, computed in step 2's read pass)
instead of raw samples, so an hour costs 1.4 MB rather than 460 MB of
resident audio; the maths is unchanged, since the original's first step is
that envelope. Constants: 10 s windows, ±0.2 s lag search, per-window
correlation 0.7, affected share 0.15, at least three windows scored and two
affected, −70 dBFS silence floor. Our `EchoVerdict.init(_ result: Result?)`
maps nil to `.notMeasured`, `isAffected` to `.affected`, else `.clean`. No
tests come with it; ours (`EchoBleedDetectorTests`): two silent envelopes →
`.notMeasured`; the mic envelope copied into the far end 50 ms later →
`.affected`; two independent noise envelopes → `.clean`.

`MeetingTranscriber` (enum with one entry point, run in a detached task,
inside `ProcessInfo.processInfo.beginActivity(options: .userInitiated,
reason: "transcribing a meeting")`, ended on every exit path. A menu-bar
accessory doing a minute of CPU work in the background is the textbook App
Nap case, and a napped transcription finishes whenever macOS gets round to
it. The recorder holds the same activity for the length of a meeting; the
IOPM assertion (7.6) is what names the reason in `pmset -g assertions`, this
is what keeps the drain queue and the tick at full speed.)

1. If `ModelStore.isInstalled` is false, stay `pending`, save and return;
   `MeetingStore` re-queues every `pending` meeting when the install
   finishes. Otherwise set `transcription.state = running`, save.
2. For each track: read the `.caf` once to compute the 100 ms peak envelope
   (for `ChunkCutter`) and the 10 ms RMS envelope (for the echo detector),
   cut with `ChunkCutter`, then for each chunk not yet in `done` read only
   that chunk's samples. A chunk whose peak envelope never rises above
   `Fixed.meetingSilenceFloor` is marked done and skipped without a model
   call: a call where the far end stays muted is 40 minutes of silence that
   would otherwise be decoded a chunk at a time, and the envelope needed to
   tell is already in hand from this same pass. Otherwise call `await Transcriber.shared.transcribeMeetingChunk(chunk)`,
   offset every word by the chunk's start, stitch with `ChunkStitch.append`,
   append the words to a per-track scratch file (`words-mic.json`,
   `words-others.json`, a `TrackWords`) and bump `done`, saving
   `meeting.json`. Memory stays at one chunk. A chunk that fails with
   `TRANSCRIBE_ERR_OOM` (`Transcriber.Error.status(code, _)`) is halved and
   retried once; if a half fails again, or the status is anything else
   (`TRANSCRIBE_ERR_BACKEND` is not retryable), its span is marked
   `[unreadable]` and the loop continues. A chunk with speech in it that
   comes back with no words is retried once, trimmed and louder: Parakeet
   returns nothing on quiet speech rather than something wrong, and a room
   track's far side of the table or a far end with low gain is exactly
   that. "Speech in it" is peak ≥ 0.010, RMS ≥ 0.0015, ≥ 0.5% of samples
   above the activity threshold (8% of peak, clamped to 0.003…0.020) and
   ≥ 0.2 s of them. The retry trims to the first and last active sample
   with 0.25 s either side and scales so the peak is 0.45, gain clamped to
   1…12. All of it is the shipping notetaker's dictation recovery on its
   own runtime of the same model family; S2 confirms it on ours by feeding
   a chunk at −30 dB. Report progress as chunks done over chunks total
   across tracks.
3. Echo: for a call, run `EchoBleedDetector` over the two RMS envelopes from
   step 2 and store the verdict in `echo`.
4. `TranscriptMerge.paragraphs(tracks: [TrackWords], segments: [SpeakerSegment]?, dictations: [Span], gap: Duration) -> [Paragraph]`
   (pure): phase 1 passes two tracks labelled `you` and `them` and no
   segments. Drop mic words whose midpoint lies inside a dictation span.
   Sort every word by start. Start a new paragraph on a speaker change or a
   gap over `gap`. On `echo == .affected` nothing is dropped; the row says so
   (7.11). Tests: interleaving, dictation removal, gap splitting, an empty
   track.
5. `talkMs` per speaker from the words' spans. Save with `state = done`,
   `tookMs`, `asr` from `ModelStore.fileName`; delete the scratch files.
   Transcode (7.9) and rename the folder with the duration, still in staging.
6. Publish. If the published folder's parent resolves
   (`FileManager.fileExists`), move the folder there, set `published = true`,
   save, and show `.meetingSaved(id:)` unless the settings window is showing
   the tab. If it does not resolve, leave the folder in staging with
   `published = false`, show `.meetingFolderUnavailable`, and let the row
   carry the chip `meetings folder unavailable` with `change`; `MeetingStore`
   republishes it later (7.9). A publish failure never touches
   `transcription.state`.
7. Any error thrown in steps 1 to 5: `state = failed`, `error` text, keep the
   `.caf` files in staging, show `.meetingFailed(id:)`. The row offers
   `retry`, which starts at step 1 and skips chunks already in `done`.

Disk: `MeetingRecorder` checks free space on the staging volume every
minute; under `Fixed.meetingMinimumFreeBytes` (500 MB) it stops the meeting,
keeps what exists, and the coordinator shows `.meetingDiskFull`.

Optional, small, at the end of phase 1: a title from the transcript when
Apple Intelligence is available. A separate `LanguageModelSession` (never
`PostProcessor.shared`) with a `@Generable struct MeetingTitle { @Guide(description: "three to five words") var title: String }`
over the first `Fixed.meetingTitleSourceWords` (700) words; `titleSource = generated`; never overwrites a user
title; skipped silently when the model is unavailable.

### 7.11 The Meetings tab, the settings group, the menu and the puff

`SettingsTab.meetings` after `.history`, label `meetings`, icon
`akar-people-group`; `SettingsTab.available` keeps it, since its filter
removes insights only. `MeetingsTab` follows `HistoryTab`'s structure:

- Top bar: search field (matches title, paragraph text and speaker names),
  `counted(n, "meeting")`, `delete N` when rows are selected, `delete all`
  with the same confirmation dialog pattern.
- A status row above the list while something is live: `recording · 12m`
  with a `stop` button and two level meters (mic, others); or
  `transcribing · 40%` with an `InkProgress`; or `downloading the speaker model · 40%`
  (phase 2).
- Groups by day exactly as History does (`today`, `yesterday`, `19 september`).
- Row: select box · start time (`14:30`) · title · buttons on the right.
  Second line in the `telemetry` style: `45m · counted(speakers, "speaker") · slack`,
  then chips in the `edited` style when they apply: `only your side` (the
  others track never left the floor), `on speakers` (`echo == .affected`),
  `transcription failed` with a `retry` button when `state == failed`,
  `waiting for the speech model` with `download` when `state == pending` and
  `ModelStore.isInstalled` is false (never both), `meetings folder
  unavailable` with `change` when `published` is false and the folder does
  not resolve.
- Buttons: `akar-play`/`akar-stop` (help `play` / `stop`; shown only when
  the meeting has an `.m4a`; a call plays both tracks together),
  `akar-copy` (`copy the transcript`), `akar-pencil`
  (`rename`; the title becomes a `TextField`, return saves, escape cancels),
  `akar-arrow-forward-thick` (`show in finder`), `akar-trash-can` (`delete`).
- Expanded row (click on the body): the paragraphs, each `**You** · 0:14` in
  the small monospaced style with the text below, selectable. Phase 2 makes
  each speaker label clickable to rename.
- Empty state: `nothing yet` / `no matches`.
- Footer under a `RowRule`, like History's keep rows: `keep` (picker `the
  last 50 meetings` … `everything · never delete`), `keep the audio` (toggle,
  subtitle `deleted along with the meeting`), `meetings folder` (subtitle the
  path with `~` for home, ` · icloud drive` appended inside iCloud Drive's
  container, or `unavailable` when it does not resolve; buttons
  `show` and `change`; `change` opens an `NSOpenPanel` for directories and
  moves nothing), `system audio` (status `not tested` / `working` / `silent`,
  button `test`: taps our own process while playing `pop_stop.wav` and
  reports whether signal arrived; a silent result shows `system settings` and
  the line `quit and reopen after granting`; under it, always, the line
  `the other people on a call are not told you are recording.`, D19), and a
  `meetings use 2.3 GB` line, omitted while the folder is unavailable.

Main settings tab, group `meetings` after `microphone`: `record meetings`
(picker `ask` / `never`, `HelpMark`: `a call is detected when another app
opens the microphone. nothing is recorded until you say record.`), `never ask
for` (chips with a cross each, cross help `ask again for zoom`; hidden when
empty), `record the room` (`ShortcutRecorder`, phase 2), `recognise my voice`
(phase 3), `names from the screen` (phase 3).

Menu (`MenuContent`), in the recording block:

- While `detected != nil` and nothing records, whatever the machine's state
  (idle for a call already running at launch or a never-ask app, candidate,
  prompting, declined): `Record This Meeting`, and `Don't Ask for Slack Again`
  unless Slack is already on the list or the owner is shared web content
  (7.2). The item sends `record(detected)`.
- While idle (phase 2): `Record the Room`.
- While a meeting records: a disabled `Recording this meeting · 12m` line
  and `Stop Recording Meeting`.
- While transcribing: a disabled `Transcribing meeting · 40%` line.
- Beside `View All…`: `View Meetings…`.

Puff: `MenuBarIconRenderer.puff(recording:transcribing:struck:updateReady:meeting:)`
draws a 5 pt dot at the bottom left in `recordingTint`, cut away underneath
the way the update dot is at the top right, for the whole meeting and
independently of the dictation tint, so a dictation inside a meeting reads
as orange mark plus dot. `AppState.meeting` is set by the coordinator.

### 7.12 Permissions

- `project.yml` → `info.properties.NSAudioCaptureUsageDescription`, and the
  same key in `Support/Info.plist`: the string in section 11.
  `NSDocumentsFolderUsageDescription`, `NSDesktopFolderUsageDescription`,
  `NSDownloadsFolderUsageDescription`, `NSRemovableVolumesUsageDescription`
  and `NSNetworkVolumesUsageDescription` likewise, one string (7.9): the
  open panel is unrestricted, and a non-sandboxed app is prompted per folder
  class the first time it lists one it did not create.
- No onboarding step. The first record click starts the tap and macOS
  prompts. If the tap then stays at the floor (7.6) the pill says so and the
  tab's `system audio` row offers `test` and `system settings`.
- `SecureInput.systemAudioSettingsURL` as in 7.7.
- `MissingPermission` is not extended: there is nothing public to poll.
- No new entitlement, so the release script's entitlement check (3.4) is
  untouched. If a build ever fails it, something other than this feature
  added an entitlement.

### 7.13 Verification

On a real machine, each of these, with debug logs on and the log read afterwards:

- Slack huddle: the prompt appears within 15 s of joining; `record` starts
  both tracks; `others.caf` has signal; leaving the huddle ends the meeting
  after `meetingResumeSeconds`; the folder is `… 12m Slack`; the transcript
  has **You** and **Them** in the right places.
- Meet in Chrome, and again in Safari: the same, named Chrome, and
  `web content` for Safari (7.2).
- Meet tab behind another tab: still detected.
- Leave and rejoin within 30 s: one meeting, one gap in both tracks,
  `recordedMs < durationMs`, words after the gap aligned with the mic, and
  the pill said `recording again`.
- Leave a call and join a different one 90 s later: two meetings, and the
  second one prompted.
- Share the screen in Meet, then get prompted: the prompt is not in the
  shared view.
- Set the meetings folder to an external disk, eject it, record a short
  call: the transcript exists and is `done`, the row says the folder is
  unavailable, remounting the disk publishes it.
- A one-hour call on headphones, then on speakers: mic and far-end words stay
  aligned end to end; the speakers run is `echo: affected` and the row says
  `on speakers`; nothing is missing from either side.
- Slack mic test: no prompt. A Slack voice message: no prompt.
- YouTube in another Chrome tab while a Meet is open: detected as Chrome; the
  far end includes the YouTube audio (expected; the prompt is the guard).
- Launch the app during a call: no prompt; `Record This Meeting` in the menu
  works.
- `Don't Ask for Slack Again`: the toast, `undo` works, the chip appears in
  settings, the next huddle does not prompt until the chip is removed.
- Decline, then drop and rejoin the call within two minutes: no second prompt.
- Dictate mid-meeting: the dictation pastes; the meeting transcript does not
  contain it; `dictations` has one span whose frames match the dictation's
  audio; the call stayed audible; no cue played.
- Dictate while the end-of-meeting pass runs: the dictation starts within
  one chunk time.
- Switch the output device mid-call, and unplug the mic mid-call: the meeting
  continues, the outage is in `gaps`, timestamps after it still line up.
- Deny the grant: `system audio is off` within 90 s; the meeting saves with
  `only your side`; `test` in the tab reports silent; grant; `test` reports
  working (or says to quit and reopen).
- A 30-second call: nothing kept.
- Quit the app mid-meeting: the meeting is saved with what was recorded and
  transcribed on relaunch. `kill -9` mid-meeting: the same.
- Quit mid-transcription: relaunch resumes at the next chunk.
- Join a call, say a sentence, wait for the prompt, then record: the sentence
  is in the transcript, `preRollMs` is set, and word timestamps still line up
  with the audio.
- Decline instead: nothing is written, and the staged folder never appears.
- Leave the prompt unanswered until the candidate lapses: same.
- Import a 30-minute recording: a meeting appears, transcribes and publishes
  like any other, and re-importing the same file makes a second meeting
  rather than overwriting the first.
- Add the MCP binary to a client with the setting off: it connects, lists its
  tools, and every call says where the switch is. Turn it on: the same client
  lists, searches and reads without restarting the app, and with the app
  quit.
- Point the meetings folder somewhere else: the binary follows the setting,
  and a path argument aimed outside it is refused.
- A Sparkle update becomes ready mid-meeting: the app does not relaunch until
  the meeting is done.
- Rename to `#design/ops: Q3 · 🎉`: the folder name is legal, opens from the
  tab, and `transcript.md` is rewritten.
- Delete a meeting: it is in the Trash. Delete all: the folder is empty.
- `keep` set to its smallest option with more meetings than that: the oldest
  go to the Trash and the disk line drops.

### 7.14 Importing a recording (D21)

One file in, the same pipeline, a meeting out. Built early, because S2 and S3
need an hour of real audio and this is how they get it without staging a
meeting with three people in it.

`MeetingImport.run(url:) async throws -> Meeting`:

1. Read with `AVAudioFile`; if that refuses the container (a `.mp4`, a
   `.mov`), fall back to `AVAssetReader` over the asset's first audio track.
   No audio track at all throws `MeetingImport.Error.noAudio`.
2. Convert to 16 kHz mono Float32 with `AVAudioConverter`, mixing every
   channel down, in blocks, and write through the existing `TrackWriter` to
   `room.caf` in a staged folder (7.9). Memory stays at one block; a
   four-hour file is bounded by disk, and the same
   `Fixed.meetingMinimumFreeBytes` check applies.
3. Write `meeting.json` with `kind: room` (one track, so speakers come from
   diarization and never from a channel split), `source: imported`,
   `importedFrom` the basename only — never the path, which carries the
   user's home directory and often a client's name — `started` from the
   file's `creationDate` when it has one, else now, and
   `transcription.state = pending`.
4. Hand it to `MeetingTranscriber`, which runs unchanged from step 1, and to
   `MeetingStore`.

Entry points: `import…` in the Meetings tab, an `NSOpenPanel` filtered to
`UTType.audio` and `UTType.movie`; and a drop on the tab's list. Several
files selected at once import one at a time, since they share the one model.
The title is the file's basename, renameable like any other. The row shows
`imported` where a call shows its app.

Two honest limits, both stated in the tab rather than discovered: the model
is English, so another language returns confident nonsense; and an imported
file has no mic/far-end split, so phase 1 labels everyone `Speaker 1` until
phase 2's diarizer is installed, and `You` only from phase 3's voice print.

Tests (`MeetingImportTests`): a short `.m4a` fixture, an `.mp4` with one
audio track, a stereo file (both channels present in the mono output), a
file with no audio track, and a name that needs sanitising (7.9).

### 7.15 Querying meetings over MCP (D22)

A meeting is worth more if the tools the user already works in can read it.
The storage decision makes this cheap: a published meeting is a folder with
`transcript.md` (YAML front matter plus text) and `meeting.json`, so a reader
needs no database, no IPC and no running app.

`typemeit-mcp`, a second `project.yml` target (`type: tool`, macOS), built
into `Contents/MacOS/typemeit-mcp` of the same bundle, signed with the same
identity, sharing `Meetings/Meeting.swift` and `MeetingFolder.swift` through
a small source list rather than a copy:

- **stdio, never a port.** JSON-RPC over stdin and stdout, launched by the
  client. Nothing listens, so there is no auth to design, nothing another
  local process can connect to, and nothing a web page can reach. It works
  with the app closed, which is most of the time.
- Methods: `initialize` (echo the client's protocol version; pin the exact
  string against the current MCP spec when it is built, not from memory),
  `tools/list`, `tools/call`, and the matching notifications. Roughly 200
  lines of framing; no SDK dependency.
- **Read-only, and it never writes anywhere.** No delete, no rename, no
  re-transcribe. Writes would need the app running to keep the UI honest;
  section 10 has them.
- **Off unless the user turns it on.** The binary cannot be stopped from
  being launched, so the switch lives in the binary: it reads
  `UserDefaults(suiteName:)` for the bundle id of the `.app` it is inside
  (derived from its own path, so the dev build reads
  `it.typeme.typemeit.dev`), and with `meetingsMCP` false every tool returns
  one error telling the user where the setting is. Default false.
- **Scope.** Only `Settings.meetingsFolder ?? Store.directory/Meetings`, its
  own published folders, and only `transcript.md`, `meeting.json` and the
  folder names. It resolves every path and refuses anything that lands
  outside, symlinks included. It never reads the audio, the history, the
  dictation archive or the voice print.

Tools:

| Tool | Arguments | Returns |
| --- | --- | --- |
| `list_meetings` | `from`, `to` (dates), `app`, `kind`, `speaker`, `limit` (default 40) | One row per meeting from the front matter only: id, title, started, duration, kind, app, speakers, folder |
| `get_meeting` | `id`, `part` (default 1) | `transcript.md`, whole when it fits `Fixed.meetingMCPBudgetBytes` (24 KB), else that part and a count of the rest |
| `search_meetings` | `query`, `limit` (default 20) | Case- and diacritic-insensitive literal matches, each with the meeting, the speaker, the timestamp and the paragraph it sits in |
| `meeting_stats` | `from`, `to` | Count, total duration, talk time by speaker |

`list_meetings` reads front matter only, so a library of a few hundred
meetings lists without touching the text; `search_meetings` reads the bodies
and caches by modification date. No embeddings, no index: a client that can
query five times and read the plausible answers does better with repeated
literal search than with one vector guess, and this way there is no model, no
key and no cost.

**Transcript text is data, never instruction.** Every tool result says so on
the way out, and a transcript is wrapped as quoted content rather than
inlined bare. A meeting contains other people's speech, and the client
holding these tools usually also holds a shell and an editor, so it is a
better injection target than anything else this app produces. `get_meeting`
and `search_meetings` carry a one-line reminder in the result itself, not
only in the tool description, since the description is far away by the time
the text arrives.

**No keyword-extracted "decisions" or "action items".** A shipping notetaker
writes those into every transcript's front matter from cue lists ("let's",
"have to", "we decided") so rollup tools cover every meeting. Rejected here:
conversation is full of "let's" and "have to" that commit nobody to
anything, and once a guess sits in front matter a client reads it as a
fact. The client holding `get_meeting` extracts decisions better than a cue
list, and asks for exactly the window it wants with `list_meetings`.

**Errors are content.** A missing folder, an unreadable file or a bad
argument returns an error result; the process stays up. It never traps, and
it never prints anything but JSON-RPC to stdout (diagnostics go to stderr).

Setting up: the Meetings tab footer gains an `mcp` row with the toggle and a
`copy command` button that puts
`claude mcp add --scope user typemeit -- "<path to the binary>"` on the
clipboard, using this build's own path, so the dev app copies its own. A
second button, `copy for claude desktop`, copies the `mcpServers` entry for
`~/Library/Application Support/Claude/claude_desktop_config.json`; we do not
edit another app's config file ourselves in this plan (section 10). When the
app is running translocated (its bundle path is under `AppTranslocation`,
which Gatekeeper does to a quarantined app launched from where it was
downloaded) both buttons are disabled and the row says to move the app to
Applications first: the path they would copy is random and gone on the next
launch. The
help line says what it means — that the meetings become readable by whatever
model that tool uses, which for most clients is not on this Mac. It is the
one place this app sends meeting text off the machine, and it only does it
because the user asked.

Tests (`MCPTests`, pure over a fixture folder of three meetings): framing of
a request and response pair; `list_meetings` filters by date, app and
speaker; `get_meeting` budget split and reassembly; `search_meetings` finds a
word across two meetings with the right speaker and timestamp; a path
argument pointing outside the folder is refused; every tool with the setting
off returns the same error.

## 8. Phase 2: the room, and speakers

### 8.1 The room

- `Shortcuts`: `Settings.recordRoomShortcut` matched while idle, like
  `copyLastShortcut`, emitting `.roomRequested`; while a room records it
  emits `.roomStopRequested`. `Pipeline.handle` forwards both to the coordinator.
- Menu: `Record the Room` while idle; `Stop Recording Meeting` while recording.
- The coordinator sends `.room` to the machine; the recorder runs with
  `Kind.room`: one `TrackWriter` on `room.caf`, no tap, no minimum length,
  no prompt. The puff dot shows for the whole recording.
- One meeting at a time. `room` while any meeting records changes nothing,
  and a call detected while the room records is not offered: the room holds
  the mic on purpose, and the two transcripts would mix. `Stop Recording
  Meeting` is the way out of either.
- A room ends by `stop`, by the session cap, or after
  `meetingBothSilentEndSeconds` of its track at the floor (7.6); no silence
  pill, since there is no tap.
- `title` defaults to `Room`; the optional title step may replace it.
- Until 8.3 ships, a room transcript has one speaker, `Room`, and the row
  says `1 speaker`.

### 8.2 FluidAudio

- `project.yml` packages: `FluidAudio` from
  `https://github.com/FluidInference/FluidAudio`, pinned to the exact version
  S3 built with. If `xcodebuild` ever fails with "Multiple commands produce"
  on a module map, the cause is a second static-library xcframework; see 3.3.
- `DiarizerModelStore`, modelled on `ModelStore`: one `.tar` of the offline
  pipeline's files (3.3), hash-pinned, downloaded from a
  `model-fluidaudio-diarizer-<version>` release of this repo. It unpacks to
  `<DiarizerModelStore.directory>/speaker-diarization/` holding
  `Segmentation.mlmodelc`, `FBank.mlmodelc`, `Embedding.mlmodelc`,
  `PldaRho.mlmodelc` and `plda-parameters.json`; that subfolder is what
  FluidAudio's `Repo.diarizer.folderName` resolves to, and the `.mlmodelc`
  files are looked for nowhere else. `isInstalled` checks all five paths.
  The download lands in a temporary directory, is hash-checked, untarred
  there and moved into place with one rename, so an interrupted download or
  extraction leaves nothing behind; a failed check deletes the temporary
  directory. Makefile targets `diarizer-model` (download the pinned Hugging
  Face revision into `build/`, tar it with the upstream `NOTICE.md`
  unchanged, print the constants), `diarizer-model-verify`,
  `diarizer-model-publish` and `diarizer-model-verify-url`, mirroring the
  existing `model-*` targets. Downloaded on the first meeting that needs it,
  with the tab's status row showing progress; until then meetings transcribe
  with `Them`, and once the model is installed the row offers `add speakers`,
  which re-runs steps 2 to 6 of 7.10 on the far-end or room `.m4a` (the
  `.caf` is gone by then) with diarization on. The chip is hidden when that
  file is absent (keep the audio off).
- Attribution: the about row in the main settings tab shows the string in
  section 11, and the tar carries `NOTICE.md`, so the mirror redistributes
  the terms with the weights.
- Loading: set `ModelHub.offlineMode = true` once at launch, before any
  FluidAudio loader is touched; without it a missing or incomplete file
  starts a Hugging Face download, which D7 forbids. Never call
  `OfflineDiarizerManager.prepareModels`: its catch path deletes the whole
  `speaker-diarization` folder on any load error, offline or not, which would
  destroy the pinned archive. Load with
  `OfflineDiarizerModels.load(from: DiarizerModelStore.directory, configuration:)`
  then `manager.initialize(models:)`, and keep that one initialised
  `OfflineDiarizerManager` for the life of the process. S3 checks all three.
- `Diarizer.run(url: URL) async throws -> (segments: [SpeakerSegment], embeddings: [String: [Float]])`
  wraps that manager. `computeUnits: .cpuAndNeuralEngine` and the
  `stepRatio` S3 chose (`Fixed.meetingDiarizerStepRatio`) are baked into the
  `OfflineDiarizerConfig` when the manager is built, since the config is
  fixed at construction. The embeddings are the run's `speakerDatabase`,
  returned in memory and never stored (D18).
  `Diarizer.embedding(of pcm: [Float]) async throws -> [Float]?` runs the
  same pipeline over a one-speaker clip and returns its `speakerDatabase`
  entry, or nil unless exactly one speaker came out, so a voice print and a
  meeting's speakers come from one model.

### 8.3 Speakers

- For a call, diarize the far-end track; for a room, the room track (the
  `.caf` in the first pass, the `.m4a` on `add speakers`). Speakers become
  `s1…sN` in first-appearance order with names `Speaker 1…N`; the mic track
  stays `you`. The embeddings `Diarizer.run` returns are handed to phase 3's
  match in the same pass and discarded with it; `meeting.json` never carries
  one (D18). On a call, when the far end has one speaker, the label stays
  `Them`.
- `TranscriptMerge` assigns each far-end word to the segment containing its
  midpoint; if none, to the nearest segment within 1 s; else to the previous
  word's speaker. Tests: a word between two segments, a word before the first
  segment, overlapping segments (the one whose centre is nearer wins).
- `transcription.diarizer` records the pipeline name and version.
- **The mic track stays `you` even when two people share it.** Two of us
  round one laptop is an ordinary call, and the mic is then two voices under
  one label. Accepted for now rather than solved: diarizing the mic track as
  well costs a second run, and on a speakers call its bleed makes the result
  worse than the label it would replace. Section 10 carries it. What must not
  happen is the inverse — a stray far-end chunk (a notification chime during
  an in-person meeting) routing a room down the call path and collapsing
  everyone in it to `You`. The room is chosen by the user, never inferred
  from the presence of far-end audio, so this is a property to keep, not a
  fix to make.
- The diarizer failing keeps the transcript with `Them` (or `Room`) and logs;
  it does not fail the meeting.
- On `echo == .affected`, mic-side audio is never used for speaker
  embeddings (phase 3's print is not folded from a speakers call).

### 8.4 Renaming a speaker

In the expanded row a click on a speaker label turns it into a `TextField`;
return calls `MeetingStore.rename(speaker: id, to: name, in: meetingId)`,
which updates `speakers[].name`, saves and re-renders. Names are per meeting
in phase 2.

### 8.5 Verification

- Three-person Meet: three speakers on the far end plus **You**; paragraphs
  attributed correctly on a two-minute sample checked by ear.
- Six people round a table, started from the menu and from the shortcut: six
  speakers, no merge into four; the transcript has the room's words.
- Rename `Speaker 2` to `Ana`: the row, the expanded transcript and
  `transcript.md` all say Ana.
- Pull the diarizer archive mid-download: the row says so and offers retry;
  meetings still transcribe with `Them`.
- Press the room shortcut while a call records: nothing changes. Join a
  huddle while the room records: no prompt; the room continues.
- Leave a room recording running in an empty room: it ends after ten
  minutes at the floor, with no pill, and is kept.

## 9. Phase 3: names

### 9.1 You, in a room

`VoicePrint` (enum plus a Codable `Print { centroid: [Float]; count: Int; updated: Date }`
stored at `Store.directory/voiceprint.json`):

- When `Settings.voicePrintEnabled` turns on: decode up to
  `Fixed.meetingVoicePrintTargetSamples` (50) of the newest kept dictation
  recordings longer than `Fixed.meetingVoicePrintMinimumClipSeconds` (5 s)
  (`RecordingArchive.url(for:)` via `AVAudioFile`, already 16 kHz),
  `Diarizer.embedding(of:)` each, skipping clips that return nil, and
  average the L2-normalised vectors into the centroid. The kept archive is often empty (`keepRecordings` is off by
  default), so the print also grows from live dictations: after every
  dictation longer than `meetingVoicePrintMinimumClipSeconds`, `Pipeline` hands the
  in-memory `pcm` to `VoicePrint.fold(_:)` before discarding it, until
  `count` reaches `meetingVoicePrintTargetSamples`. No audio is kept. The print is
  not used below `Fixed.meetingVoicePrintMinimumSamples` (10).
- Turned off, or `Store.deleteAllHistory()`: delete the file and set
  `voicePrintEnabled = false`.
- Matching, in `TranscriptMerge`'s caller: for a room with a usable print,
  the speaker whose embedding has cosine distance to the centroid below
  `Fixed.meetingVoicePrintDistance` (0.40) and at least `Fixed.meetingVoicePrintMargin`
  (0.10) nearer than the runner-up is renamed `You`. Both numbers are
  meeting-transcriber's `SpeakerMatcher` defaults (MIT); S3 replaces them
  with measured ones. For a call, a far-end speaker that matches is echo;
  label it `You (echo)`, log it, and leave the echo verdict to the detector.
- Test the matcher with synthetic unit vectors.

### 9.2 Names from the meeting window

Gated by `Settings.rosterEnabled` and by S4's result, per target:

- Accessibility route (no new permission; skipped when
  `Sandbox.readsOtherApps` is false): at record time and every
  `Fixed.meetingRosterPollMinutes` (5), `Roster.fromAccessibility(pid:)`
  finds the app's windowed process
  (`NSRunningApplication` for the owner's bundle id, never the audio
  helper's pid), sets `AXManualAccessibility` (Electron) or
  `AXEnhancedUserInterface` (Chrome, then waits 3 s), walks the
  `AXWebArea`s, collects the strings S4 identified as participant names, and
  clears the attribute when the meeting ends. App-specific paths live in one
  table in `Roster.swift` with the app version they were observed on. The
  cost is the browser running in screen-reader mode for the meeting, which
  the setting's help text says.
- Screen route (needs Screen Recording, asked when the toggle turns on with
  `CGRequestScreenCaptureAccess`, exactly as `cloudMatchesBackdrop` does):
  `ScreenContext` gains `window(pid:where:)` taking a predicate;
  `Roster.fromScreen` captures the windowed process's window whose title
  contains the meeting name (`Meet`, `Huddle`), once at record time, once
  after every rejoin, and once every `meetingRosterPollMinutes` if the
  previous capture found nothing, keeping lines of one to three capitalised words not in a
  stoplist of UI words; a line starting with `#` is the channel.
- Store `roster: { channel: String?, names: [String] }` in `meeting.json`.
  Title ladder: `#channel, Ana +2` (first names, alphabetical, at most two
  spelled out, the user's own name excluded when it matches
  `NSFullUserName()`) → generated → app. Speaker labels stay numbers unless a
  roster of exactly one other name exists on a call, in which case `Them`
  takes that name.

### 9.3 Verification

- A room recording with the print on: **You** is the user; with it off:
  numbers.
- A 1:1 huddle with the roster on: the folder reads `… 20m Ana` (the
  ladder's first rung) and the far end is labelled Ana.
- A huddle with the roster off: `… 20m Slack`.
- Clear history: `voiceprint.json` is gone and the toggle is off.
- Chrome's CPU while the attribute is set, noted in the setting's help text
  if it is more than a few percent.

## 10. Later

Not in this plan, written down so they are not re-derived:

- Live speaker labels (needs a streaming diarizer; LS-EEND or Sortformer
  through FluidAudio).
- Echo removal. Voice-processing I/O would have to run on a separate
  engine, ducks every other app's output (the far end included, before or
  after the tap, unknown) and cannot be scoped away from a dictation taken
  on the same node. A shipping MIT notetaker settled the first half of that
  unknown the expensive way: the unit takes the device in *both* directions,
  and the user stops being able to hear the person they are talking to. Its
  source carries the finding as a comment next to the call it does not make; text dedup deletes the user's own sentences in
  meeting-transcriber's measurements and ships off by default there. The
  detector in D14 is the whole answer until someone measures one of these.
- Diarizing the mic track on a call, so two people at one laptop are two
  speakers rather than one `You` (8.3). Gated on echo: worth it on
  headphones, probably harmful on speakers.
- Power assertions as a second detection channel; the calendar as an end
  signal.
- Native apps' accessibility trees (Zoom, Teams).
- Talk time and meeting counts on the Insights page (`InsightRow` has no
  speaker column; a new row type).
- Speaker names remembered across meetings (a speaker database keyed by
  embedding, the rest of meeting-transcriber's `SpeakerMatcher`). When it is
  built it lives under `Store.directory`, never in a published folder, behind
  a setting, and `deleteAllHistory()` deletes it (D18). CAM++ as a dedicated
  embedding model if the pipeline's embeddings prove weak.
- One-click `connect` for MCP clients: merging our entry into Claude
  Desktop's, Cursor's and Codex's own config files, with a backup when the
  file is not valid JSON, and `claude mcp add` run for the user. Worth it once
  the copy buttons show people use this; it means writing other apps' files.
- Listen-only calls. A webinar or an all-hands joined muted may never open
  the mic, so the candidate never forms. Output alone is a usable signal
  only for a native conferencing app — Slack's own process, never a browser,
  whose output is YouTube as often as Meet — and needs a longer sustain than
  input so a notification sound does not count.
- MCP writes — rename a speaker, retranscribe, delete. They need the app
  running to keep the tab honest, so the binary would become a pump to a Unix
  socket in `Store.directory` and fall back to read-only when the app is
  closed (7.15). Still no port.
- Streaming dictation.
- A store build. It would also take the MCP binary with it: a sandboxed
  helper reaches a user-chosen folder only through a bookmark the app holds,
  which a separately launched process does not have. Whether a process tap
  can be created inside the App Sandbox is unverified; if it cannot, the store build hides meetings behind
  `Sandbox.isActive` the way it hides insights.

## 11. Copy

| Where | String |
| --- | --- |
| Info.plist `NSAudioCaptureUsageDescription` | `type me it records the other side of a call when you ask it to record a meeting.` |
| Info.plist folder keys (Documents, Desktop, Downloads, removable and network volumes) | `type me it keeps your meetings in the folder you chose.` |
| Pill prompt | `record this meeting?` · `record` · cross help `Not now` |
| Pill, never asking | `won't ask for slack again` · `undo` |
| Pill, grant missing | `system audio is off` · `system settings` |
| Pill, saved | `meeting saved` · `show` |
| Pill, failed | `meeting not transcribed` · `show` |
| Pill, disk | `disk full · meeting stopped` · `show` |
| Pill, resumed | `recording again · slack` · `stop` |
| Pill, folder | `meetings folder unavailable` · `settings` |
| Menu | `Record This Meeting` · `Don't Ask for Slack Again` · `Record the Room` · `Recording this meeting · 12m` · `Stop Recording Meeting` · `Transcribing meeting · 40%` · `View Meetings…` |
| Sidebar, page title | `meetings` |
| Tab count | `counted(n, "meeting")` |
| Tab buttons | `import…` (help `transcribe a recording`) |
| Tab status | `recording · 12m` · `stop` · `transcribing · 40%` · `downloading the speaker model · 40%` |
| Row line 2 | `45m · counted(n, "speaker") · slack` / `imported` |
| Row chips | `only your side` · `on speakers` · `transcription failed` · `retry` · `waiting for the speech model` · `download` · `add speakers` · `meetings folder unavailable` · `change` |
| Row button help | `play` · `stop` · `copy the transcript` · `rename` · `show in finder` · `delete` |
| Empty | `nothing yet` · `no matches` |
| Import | `english only` · `no audio in that file` |
| Footer row `mcp` | `let other tools read your meetings` · `copy command` · help `off by default. turning it on lets an assistant search and read your meetings — including ones that run in the cloud.` · error returned when off: `meetings mcp is off. turn it on in type me it settings.` |
| Delete all | `Delete all N meetings?` (counted) · `Delete All` · `This cannot be undone.` |
| Footer rows | `keep` (`the last 50 meetings` … `everything · never delete`) · `keep the audio` (`deleted along with the meeting`) · `meetings folder` (`show`, `change`) · `system audio` (`not tested` / `working` / `silent`, `test`, `quit and reopen after granting`, `the other people on a call are not told you are recording.`) · `meetings folder` subtitle `unavailable` / ` · icloud drive` · `meetings use 2.3 GB` |
| Settings group `meetings` | `record meetings` (`ask` / `never`; help `a call is detected when another app opens the microphone. the last two minutes are held in memory so a meeting does not start late, and are thrown away unless you say record.`) · `never ask for` (chip cross help `ask again for zoom`) · `record the room` · `recognise my voice` (help `finds you in a room, from your dictations. deleting your history deletes it.`) · `names from the screen` (help `reads the meeting window while it records. needs screen recording.`) |
| Speakers | `You` · `Them` · `Room` · `Speaker 1` · `You (echo)` |
| Default titles | app name · `web content` · `Room` · `meeting` |
| About row | `speakers: pyannote community-1, wespeaker and vbx (but speech@fit), converted to core ml by fluid inference · cc-by-4.0`, the licence linked to creativecommons.org/licenses/by/4.0 |

## 12. Tests

Unit tests, pure except `TrackWriterTests` (a temporary directory), one
file each under `TypeMeItTests/Meetings/`:

| File | Cases |
| --- | --- |
| `ProcessOwnerTests` | 7.2 |
| `MeetingWatchTests` | grouping and comparison of snapshots; debounce is not tested |
| `MeetingMachineTests` | 7.4 |
| `AudioRingTests` | wrap, overrun count, read after write |
| `TrackWriterTests` | header bytes; truncated file opens with the right frame count |
| `MeetingFolderTests` | `8m`/`45m`/`1h20m`; slash, colon, newline, emoji, leading dot; 200-byte cap on a grapheme; same-minute collision; case-folded collision; NFD/NFC collision; time zone |
| `MeetingCodableTests` | round trip; room variant; unknown keys ignored; `decode` returns nil for `schema: 2`; `frames == durationMs × 16` on the example |
| `TranscriptRenderTests` | snapshot of the example meeting; `h:mm:ss` past an hour |
| `ChunkCutterTests` | 7.10 |
| `ChunkStitchTests` | 7.10 |
| `TranscriptMergeTests` | 7.10 and 8.3 |
| `EchoBleedDetectorTests` | 7.10: silence, a delayed copy, independent noise |
| `PreRollTests` | 7.7: a wrapped ring drains oldest-first; a short pre-roll; `discard` leaves nothing readable |
| `MeetingImportTests` | 7.14 |
| `MCPTests` | 7.15 |
| `VoicePrintTests` | matcher threshold and margin on unit vectors |

Assertions compare whole values or snapshot the whole rendered file; no
substring checks.

## 13. Traps

- A tap without the grant is silent, not failed. Watch the floor; never
  trust the absence of an error. A far end at the floor with the mic alive
  is everyone muted, not a fault.
- Per-process `IsRunningInput`/`IsRunningOutput` listeners register fine
  and never fire. Listen to `Devices` per scope, and poll.
- Chrome's and Slack's browser processes carry no audio; the helpers do, and
  they exist before the call, so the process-list listener never sees the
  call start.
- "Running output" is true of an app's process set, not of any one process.
- `kAudioProcessPropertyBundleID` on a bundle-less process returns `noErr`
  and an empty string. Treat empty as nil.
- The dev build and the release build are two apps. Exclude both by bundle-id
  prefix, or dictating in one prompts the other.
- Muting the output device while a meeting records mutes the far end for the
  user; the tap is unaffected, so the transcript keeps words the user never
  heard. Skip mute, pause and cues while a meeting records.
- `Transcriber.abortFlag` is per session: use the second session for meeting
  chunks or a dictation cancel aborts them.
- Quit is `_exit(0)`, on purpose. Nothing after that line runs, which is why
  the tracks are CAF with an open-ended data chunk and `meeting.json` is
  rewritten on every state change.
- Sparkle relaunches the app the moment dictation is idle. Gate it on the
  meeting too.
- `OverlayPanel.show` replaces the state; a dictation would eat the prompt.
  Park it and re-show it.
- The pill is drawn into a display share unless `sharingType = .none`.
- An aggregate whose sub-device disappears stops delivering. Listen for the
  default devices, rebuild, and zero-fill the gap or every later word
  timestamp is wrong by the outage.
- Two AVAudioFile-written containers (WAV, CAF through `AVAudioFile`) get
  their sizes on close; a crash leaves a header claiming zero frames. Write
  the CAF header by hand with a `-1` data size.
- `kAudioAggregateDeviceTapAutoStartKey` must never be set on the meeting
  aggregate: with it the device does not start until the tap delivers
  audio, so a room (no tap), a denied grant or a silent far end would hold
  the mic track back, breaking D13 and the clock in 5.4.
- Zoom starts its own voice processing on the mic when a call begins. Open
  that mic first and Zoom's processing can land on our capture too, which
  is why another notetaker watches for Zoom *running*, not for it taking
  the mic. Not a launch target; it is why "Zoom works for free" needs its
  own run before anyone says so.
- The pre-roll opens the microphone at `candidate`, so the menu-bar
  indicator lights before the user has agreed to anything, and our own
  process appears in the process list holding input. The watch already
  excludes both bundle ids by prefix, so this cannot make the app its own
  candidate — but that exclusion becomes load-bearing rather than tidy.
- Audio device names are user-authored and routinely carry a real person's
  name ("Michael's AirPods Pro"). Nothing persists one: not `meeting.json`,
  not the transcript's front matter, not a log line. They may be shown live
  (a picker, a warning that names the device it cannot hear) and nowhere
  else. Today no field holds one; this is here so none is added.
- Spotlight does not index `~/Library/Application Support`. The folder
  setting exists for that; a folder in `~/Documents` may be synced by iCloud.
- FluidAudio's offline pipeline needs a different model set from the
  streaming one, defaults to `.all` compute units, and fetches from Hugging
  Face unless told where the files are.
- The pyannote/WeSpeaker weights are CC-BY-4.0: attribute them.
- Foundation Models' window is 4,096 tokens and `PostProcessor.shared`
  cancels its current task on every call: never point either at a meeting.
- Setting Chrome's or Slack's accessibility activation attribute puts the
  whole process into screen-reader mode; scope it to the meeting.

## 14. Prior art and licences

Checked on 2026-09-19 with the GitHub API and each repo's LICENSE file.
Lift only from the first group, and carry the licence notice where code is
lifted.

| Repo | Licence | Take |
| --- | --- | --- |
| `pasrom/meeting-transcriber` | MIT, active (177 stars) | `EchoBleedDetector` (constants, `Result` and `analyse`, fed envelopes; 7.10), `SilentRecordingMonitor` (the 90 s both-channels rule), `SpeakerMatcher` (0.40 / 0.10 defaults), `DualSourceRecorder.resolveTapPIDs` (tap the whole app), `MicInputDetector` (the FaceTime and WebKit.GPU facts), `AppTapSession` (teardown order), `DiarizationProcess.mergeDualSourceSegments` (the merge, written here in Swift of our own) |
| `r3dbars/transcripted` | MIT, active | The nearest neighbour: dictation *and* meetings, Parakeet (through FluidAudio's Core ML build, not transcribe.cpp), Markdown files, an MCP helper. Taken: the Bluetooth mic rule and its S1 test (7.5), the empty-chunk gain retry and its thresholds (7.10), App Nap during transcription, the decodable-tail check on transcode, the Zoom voice-processing trap, the translocation check and Claude Desktop entry (7.15). Declined, with reasons: keyword-cue decisions in front matter (7.15), a stored database of other people's voices (D18), ScreenCaptureKit for the far end (the tap is per-app, SCK is everything the Mac plays) |
| `michaelwilhelmsen/humla` | MIT, active | `OfflineDiarizerConfig` starting values and the reasons for each (S3), `withSpeakers(exactly:)` against VBx's dominant-speaker under-count, and the voice-processing-I/O finding in section 10. Ships the same FluidAudio pipeline this plan picks, so its tuning is measured on our problem, not an adjacent one |
| `insidegui/AudioCap` | BSD-2-Clause, last push 2025-08 | Tap and aggregate-device geometry, tap format read. Keep its copyright notice where code is lifted |
| `FluidInference/FluidAudio` | Apache-2.0 (library); pyannote/WeSpeaker weights CC-BY-4.0 | A dependency, not lifted code. Attribute in the about row |
| `brendanbank/atrium-pa-mac` | BSD-2-Clause | The 45 s / 2 min / 90 s starting values and the zero-buffer warning |
| `rom4lk/meeting-helper` | MIT | Input-plus-output disambiguation |
| `artcoholic/akar-icons` | MIT | The `people-group` icon |
| `handy-computer/transcribe.cpp` | MIT | Already pinned |

Read but not lifted: `makeusabrew/audiotee` (README names MIT, no LICENSE
file and no grant text; taps every process, not one app), `Mo7amed7osam/zoom-auto-admit`
(no licence, 0 stars), `iamchuck504/yapper` (no licence; its README
documents the grant's pane name and relaunch note), `abhi-wan-kenobi/notare`
(no assertion), `Zackriya-Solutions/meetily` (MIT; Parakeet ships,
diarization is "coming soon" for its paid tier), `fastrepl/anarlog` (MIT plus
an enterprise directory), `chrisns/MacWhisperAuto` (MIT; fuses network,
power, window and extension signals because CoreAudio alone missed browser
calls; its supported-app list is a test plan), `anshuman-pandey/open-granola`
(Apache-2.0).

## 15. Changes from the earlier draft

For the reviewer of this PR. The earlier `docs/meetings.md` on this branch
was an argument; this is a spec. What changed in substance:

- **Streaming dictation is dropped.** Its premise, that streaming spreads
  the encoder work out, is the reverse of what the model doc says (buffered
  streaming re-encodes about 7.4 times the audio), offline is about 158x
  realtime, and nothing the user sees changes. The commit `d18b464` should
  not merge: its `MeetingMic` is the bundle-id allowlist the plan forbids,
  its tests assert Chrome is not a meeting app, and its `LiveDictation.cancel`
  can leave the transcribe.cpp stream active for the life of the process.
  The `Transcriber` streaming methods are not kept either; chunked offline
  is the long-audio path pending S2, and if S2 picks streaming instead, the
  commit's `beginStream`/`feedStream`/`finishStream` are the reference to
  rewrite from, minus the cancel race.
- **The detection listeners the plan named do not work.** Measured here:
  per-process `IsRunningInput`/`IsRunningOutput` listeners never fire. The
  design now listens to `kAudioProcessPropertyDevices` per scope and polls
  every second.
- **Confirmation is two booleans, not tapped audio**, held 12 s. atrium,
  the source of the thresholds, taps speculatively and confirms from audio
  peaks; that is incompatible with asking first.
- **Both tracks come from one aggregate device on one clock.** The earlier
  draft captured the mic through the dictation engine and the far end
  through a separate aggregate, two clocks that drift apart over an hour and
  start with an unknown offset. Dictation is left alone.
- **One speech model.** The installed `parakeet-unified` transcribes each
  track in chunks on a second session; FluidAudio's offline pipeline
  diarizes. The multitalker bundle, the `model:` field that named it, the
  "unload one model, load the other" sequence and the 207x/111x wait
  estimate are gone.
- **`meeting.json` is the truth**; `transcript.md` is rendered. Tracks are
  CAF files with an open-ended data chunk so a crash loses nothing.
- **Consent is scoped to the call**: a cross survives a drop and rejoin of
  up to two minutes, a recording resumes after a drop of up to 30 s and says
  so, the prompt has no timer, is not drawn into a display share, and
  survives a dictation. Never-ask is an
  explicit menu item, never inferred, because two crosses on two unrelated
  Chrome calls would have silenced Google Meet.
- **Echo is detected, not removed.** Separate tracks do not stop a
  speakerphone call from putting the far end into the transcript twice; the
  meeting-transcriber detector marks it, and the dedup and voice-processing
  ideas are recorded as out.
- **Silent tap, whole-app tapping, device changes, dev-build exclusion,
  dictation folding, sleep, quit, the update relauncher, crash resume, disk
  full, retention, playback of two tracks** are specified; none were. Two
  are live bugs waiting: Sparkle relaunches the app the moment dictation is
  idle, and quit is `_exit(0)`.
- **Every open question has a default** (section 2) so nothing blocks.
- **Credits fixed.** The matcher recipe, the FaceTime trap and the echo
  detector come from `pasrom/meeting-transcriber` (MIT), now cited.
  "Dual-track diarization" was its feature, not FluidAudio's. `audiotee` and
  `zoom-auto-admit` are no longer called liftable. AudioCap and atrium are
  BSD-2-Clause, not MIT. The FluidAudio weights are CC-BY-4.0.
- **Screen Recording is not new.** `ScreenContext` already captures a window
  and OCRs it; the roster route reuses it.
