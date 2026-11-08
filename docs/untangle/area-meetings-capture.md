# Meetings: capture, recording, transcription

Each fix sits above the problems it solves.

- **The recorder owns the meeting it records.** Add one `MeetingRecorder.apply(_ result:, to meeting:)` for `finished`, `stopForQuit` and `snapshot`. It owns creating the folder, excluding it from backup, and the track file name (`Meeting.Track.rawFile(role)`). Drop the dead `Result.peaks` and `Meeting.firstHostTime`.
  - `MeetingCoordinator.swift:457-464`, `:600-607` and `MeetingRecorder.swift:279-287` copy a Result into a Meeting field by field.
  - `MeetingCoordinator.swift:463` stores `0` for `firstHostTime` where `MeetingRecorder.swift:283` stores `nil`. Nothing reads the field.
  - `MeetingRecorder.swift:80-84` and `:264-268` both create the folder and exclude it from backup, and `MeetingFolder.write` creates it a third time.
  - `"\(role.rawValue).caf"` is built at `MeetingRecorder.swift:93,102,273,321`, `MeetingTranscriber.swift:449`, `MeetingMerge.swift:54` and `MeetingStore.swift:159`.
  - `MeetingRecorder.swift:152-154` and `:303-305` both close an open pause into a gap. `:129-132` and `:333` both add host offsets. `:282` and `:330-332` both work out recorded ms.
  - `MeetingRecorder.swift:17` `Result.peaks` is written and never read.
  - `MeetingRecorder.swift:314-316` pads the end and `PreRoll.swift:197-198` pads or trims the start: two rules for keeping tracks the same length.

- **Split `MeetingCoordinator` (1306 lines) into recording plus queue on one side and Ask Claude plus hooks on the other.** The Ask Claude side takes one `ClaudeSettings` snapshot. Settings opens through one `SettingsNavigator.open(tab:reveal:)`. The machine describes itself.
  - `MeetingCoordinator.swift:828-904` and `:999-1252`: hooks and Ask Claude (about 25 fields) share a class with the recorder and the queue.
  - `MeetingCoordinator.swift:853-857` and `:1096-1100` take the same five-setting snapshot.
  - `MeetingCoordinator.swift:865` and `:1134` repeat the "not installed" answer literal.
  - The open-settings sequence (set `AppState.settingsTab`/`reveal*`, then post `MenuBarLabel.openSettings`) is written out at `MeetingCoordinator.swift:206,224,561`, `MeetingProbes.swift:94`, `Pipeline.swift:64` and `TypeMeItApp.swift:350,367`.
  - `MeetingCoordinator.swift:1264-1305`: three `describe` switches mirror every MeetingMachine case.
  - `MeetingCoordinator.swift:1206-1220`: the `previewAnswer` debug path, with its sleeps, ships in the coordinator, and its fixture is copied in `MeetingProbes.swift:306-308`.

- **Make the transcription queue its own small type.** It holds `[Meeting]`, publishes ids, launches through one path guarded by id, and publishes when a pass finishes, not on a 1 s tick. Deleting while live becomes an explicit argument, not a read of `liveIDs`.
  - `MeetingCoordinator.swift:551,622,630,681` resync `queued` with `transcribeQueue` by hand.
  - `MeetingCoordinator.swift:736-745` and `:751-759` are two detached launches. Only one guards progress by id, so a rejoin writes progress into another pass.
  - `MeetingCoordinator.swift:523,742,755`: detached tasks call `MeetingCoordinator.shared`, not `self`.
  - `MeetingCoordinator.swift:290` and `:806-812`: the tick republishes, so `transcribed()` needs a race branch, and `MeetingTranscriber.swift:205` must set `.done` last.
  - `MeetingStore.swift:165` silently skips ids in `MeetingCoordinator.shared.liveIDs`, so callers must clear running state before deleting (`MeetingCoordinator.swift:549-557,789-800`), and the store depends back on the coordinator.
  - `MeetingCoordinator.swift:453,531,536,782` remove with `try?` and `store.drop`, while other paths use `store.delete`: two delete paths with different side effects.
  - `MeetingCoordinator.swift:170` repeats `enqueue`'s duplicate check, and `:996` `isWaiting` checks sets that `liveIDs` already contains.
  - `MeetingCoordinator.swift:609` `try? MeetingFolder.write` at quit hides the one failure that loses a recording.

- **One way to rerun a meeting.** One reset function and one summary-then-title step, shared by the coordinator, the transcriber and the probes.
  - `MeetingCoordinator.swift:637-643` and `MeetingProbes.swift:135-137` reset the same fields.
  - The summary-then-title ladder is written at `MeetingCoordinator.swift:694-721`, `MeetingTranscriber.swift:186-200` and `MeetingProbes.swift:110-111`.
  - The placeholder-title rule is written at `MeetingCoordinator.swift:645-647` and `:723-725`. "Room" is a fallback at `:646` and `MeetingRecorder.swift:101`.

- **One audio-file reader and one envelope pass.** Add a `TrackReader` (`samples(range:)`, `forEachSecond`, `envelopes(peakMs:rmsHz:)`). `ChunkCutter` gives the real chunk count. EchoLag is computed once and passed into the fold.
  - "Read a file a second at a time" is written four times: `MeetingTranscriber.swift:363-384`, `:390-403`, `Diarizer.swift:198-213` and `MeetingProbes.swift:398-401,444-447`, plus `TestAudio.swift:26-32`.
  - `MeetingTranscriber.swift:390`: a general file reader lives in the transcriber, and `Diarizer.swift:229` and `VoiceLibrary.swift:419` reach into it.
  - `MeetingTranscriber.swift:354-359` `chunkCount` estimates `ChunkCutter.cuts` in closed form, so the progress total can disagree with the real cuts.
  - `MeetingTranscriber.swift:363-384` reimplements `ChunkCutter.peaks(of:)`, which has no production caller.
  - `MeetingTranscriber.swift:12-13`: `rmsEnvelopeHz` is restated as `hz: 100` in `EchoBleedDetector.swift:114,134,143`.
  - `MeetingTranscriber.swift:102` and `EchoFold.swift:320` both run `EchoLag.read` on the same envelopes.
  - `MeetingTranscriber.swift:62-63,432` and `MeetingProbes.swift:411-412,422` repeat the cutter parameters and the word-offset step.
  - The diarize-then-`absorbingShort` sequence is written at `MeetingTranscriber.swift:266,312` and `MeetingProbes.swift:497`.

- **Speaker identity in one place, next to `Meeting.Speaker`.** It holds the default names, the role↔id map, the id scheme with recognisers, and one rule for whether a name is the user, given the user's name explicitly. Move `MeetingNames` into Meeting.swift so the MCP stops compiling the naming algorithm.
  - The literals "You" and "Room" are scattered: `MeetingRecorder.swift:95-96,101`, `MeetingTranscriber.swift:239-241`, `SpeakerAssign.swift:245`, `VoiceNames.swift:33`, `MeetingSummary.swift:35`, `RosterRules.swift:95`, `MeetingCoordinator.swift:646`.
  - `MeetingTranscriber.swift:229-243` maps roles to ids, and `VoiceNames.swift:58-61` hand-writes the inverse.
  - The id prefixes `s`, `c` and `r` are spread over `MeetingTranscriber.swift:285`, `MeetingShare.swift:136`, `SpeakerNaming.swift:160` and `RoomVoices.swift:217`. Only `r` has a recogniser.
  - **Bug:** there are three "is this name the user" rules: `SpeakerNaming.swift:412-415` (exact), `SpeakerAssign.swift:71-85` (first-name prefix) and `SpeakerNaming.swift:174` (lowercased). `SpeakerCount.swift:335` and `RoomVoices.swift:227` use the strict one, so a user listed under a short form of their name counts as an extra far-end voice.
  - `MeetingTranscriber.swift:129` and `SpeakerAssign.swift:72`: pure steps call `NSFullUserName()` themselves.
  - `SpeakerNaming.swift:128-183` declares `MeetingNames` (a stored model) in the algorithm file, and `project.yml` compiles the whole algorithm into `typemeit-mcp` for it.
  - `RosterAccumulator.swift:282-309` mirrors `MeetingNames` and its `Caption` twice.
  - `SpeakerNaming.swift:227-228`: the `.user` source branch is never produced.

- **One pure file for interval and ordering helpers.** It holds `overlapMs`, `wordMs(in:)`, `talkMs`, `firstAppearanceOrder`, `median`/`percentile` and one word normaliser. The UI lag shift is applied once, when names enter the pass.
  - Six interval-overlap helpers: `SpeakerNaming.swift:371-381`, `SpeakerMerge.swift:65`, `SpeakerCount.swift:374-378`, `RoomVoices.swift:237-239`, `VoiceNames.swift:104-106` and `TranscriptMerge.swift:448`.
  - Talk-time sums: `MeetingTranscriber.swift:172`, `SpeakerAssign.swift:299`, `SpeakerMerge.swift:103-107` and `RoomVoices.swift:233-236`.
  - The first-appearance ordering loop: `MeetingTranscriber.swift:274`, `RoomVoices.swift:264-267`, `SpeakerNaming.swift:261-266,383-391` and `SpeakerCount.swift:365`.
  - `EchoLag.swift:586-600` holds generic stats that `EchoFold.swift:388` borrows, while `RoomVoices.swift:256` writes its own percentile.
  - Three "same word" normalisers disagree on punctuation: `EchoFold.swift:444-446`, `ChunkStitch.swift:98-100` and `SpeakerNaming.swift:297-299`.
  - The `meetingUILagMs` shift is applied separately at `SpeakerNaming.swift:207,210`, `MeetingTranscriber.swift:297` and `SpeakerCount.swift:366`.

- **A CoreAudio device module outside Meetings, and one capture-test sink.** Property helpers, device lookup and the host clock go into `Audio/CoreAudioDevice.swift`, used by dictation and meetings alike. One `PeakSink` serves AudioCheck, the coordinator's system-audio test and the probe. Teardown becomes one function. A conversion failure becomes a `captureGap`.
  - `MeetingCapture.swift:133-146,168-172` reimplement `AudioProcesses.swift:23-50,65-71`. `:148-150` `string` is a pass-through.
  - `MeetingCapture.swift:152-242`: device lookup lives in the meeting capture, so `AudioCapture.swift:70` and `OutputMute.swift:50,67` depend on Meetings.
  - `MeetingCapture.swift:377-399` holds the host-clock helpers, which several areas use.
  - The self-tap "did system audio arrive" test is written three times: `MeetingCoordinator.swift:910-946`, `AudioCheck.swift:185-240` and `MeetingProbes.swift:191-279`. `MeetingCoordinator.swift:925` uses a 2 s literal for it.
  - `MeetingCapture.swift:250-254` and `:565-567` repeat the tap setup, the second without name or uuid.
  - `MeetingCapture.swift:258,288,304,325`: four hand-written partial teardowns.
  - `MeetingCapture.swift:425,439,550`: three copies of the device-rate to 16 kHz conversion.
  - `MeetingCapture.swift:461` returns `[]` on a conversion error with no gap, so meeting time drifts.
  - `MeetingCapture.swift:515-520` retries with `Thread.sleep`, and `:542` waits "one drain" with `asyncAfter`.
  - `MeetingProbes.swift:282` builds a property address by hand.
  - The sample rate goes by two names, `AudioCapture.targetFormat.sampleRate` and `Meeting.framesPerMs` (`PreRoll.swift:168`, `QuietSpeech`, `TrackWriter`), and `MCP/Shims.swift:20,27` holds a third copy.

- **Tuning lives with the module it tunes.** Each `Fixed.meeting*` constant with a single user moves into that module, as EchoFold and EchoLag already do. `Fixed` keeps only values shared across modules.
  - About 75 `Fixed.meeting*` constants in `Settings.swift:425-650` each have one user.
  - `TrackWriter.swift:82,171` uses the recorder's silence window. `MeetingCoordinator.swift:485` subtracts it because it assumes when the recorder fired (`MeetingRecorder.swift:221`).

- **The machine and the roster tidy themselves.**
  - `MeetingMachine.swift:200,206,248,264,289`: the stop-recording transition is written five times.
  - `Roster.swift:175,211`: two Meet host checks with different filters. `MeetingProbes.swift:526,532,562-587` hard-code the Slack target and repeat the AX walk.
  - `WindowCapture.swift:220` and `Roster.swift:148` each toggle the same AX activation attribute, so the roster can clear it while a capture is running. Track it with a counter.
  - `Roster.swift:90`: a fixed 1 s delay before the first poll.

- **Small items.**
  - Dead: `MeetingWatch.swift:378` `stop()`, `EchoBleedDetector.swift:47` `frameSeconds`, and the `overlapMs` parameter at `ChunkStitch.swift:77`.
  - `EchoBleedDetector.swift:228-234`: the one-function enum `EchoVerdict` should be an initializer on `Meeting.Echo`.
  - `MeetingWatch.swift:442-445` duplicates `AudioProcesses.swift:210` `ProcessOwner.owner`. `:453` holds the general `Duration.timeInterval`.
  - `DiarizerModelStore.swift:269,283` types the revision twice; derive one from the other.
  - Swallowed errors:
    - `MeetingHook.swift:476,480`: a codec failure wipes the user's hooks.
    - `Diarizer.swift:112,122`: `try?` also swallows cancellation.
    - `TrackWriter.swift:128`: `try? handle.close()` on finish.
  - `MeetingTranscriber.swift:57,182,446` reads `Settings.shared` and `Store.shared` mid-pass, so `MeetingProbes.transcribeCopy` writes into the user's real voice library.
  - Eight places log the same text to both `Log.meetings` and `DebugLog`. One helper should do both.
  - `MeetingProbes.swift:46,72,80,93,97,293` wait for the app with fixed launch sleeps. `:53,300-390` render overlay pills from the meeting probes.
  - `Diarizer.swift:235-257` carries probe-only code in the production actor.
  - About 15 comments only restate the code (for example `MeetingCoordinator.swift:46`, `MeetingRecorder.swift:296`, `MeetingTranscriber.swift:228`).
