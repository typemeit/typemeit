# Tests: `TypeMeItTests/` and `Scripts/asr-eval/tests`

The rule: a test should fail on a regression, and only then. This pass comes last, after the structural fixes, because these tests are the safety net for them.

- **Remove tests that repeat the implementation.**
  - `PasteTimingTests.swift:5-22` restates `Output.swift:315-319` and the order of the `Fixed` constants.
  - `CustomWordMatcherTests.swift:95-106` restates thresholds and the penalty formula.
  - `FocusTests.swift:5-9,16-20` loop over the code's own role lists.
  - `InsightsTests.swift:91-95` restates `displayName`. `:97-101` should stay only because the raw values are stored.
  - `LearningTests.swift:364-371` is the `isVocabulary` switch as a table. `:502-512` pins nine timing constants.
  - `WritingStyleTests.swift:159-162` builds the expected value from the code's own rule.
  - `ScreenContextTests.swift:85-88` copies the prompt verbatim. Assert that the terms appear instead.
  - `DayLineTests.swift:29-31,53` check a label against itself.
  - `ClaudeRunTests.swift:60` checks `environment == environment`.
  - `TrackWriterTests.swift:40`.
  - `QuietSpeechTests.swift:38,44` restate the gain formula.
  - `MeetingFingerprintTests.swift:69-71`.
  - `ProcessOwnerTests.swift:75-78`.
  - `CameraCompositorTests.swift:16-17` (borderline).
  - `test_core.py:92`.
  - `SettingsTests.swift:112-158` pins every default. Keep the key-name and format tests (`:173,193`).

- **Rewrite tests tied to internals so they check behaviour.**
  - `CustomWordMatcherTests.swift:130-136` (`soundKey` encoding), `TokenDiffTests.swift:54-60` (`matchKey`) and `ScreenContextTests.swift:47-72` (`isCandidate`/`clean`): go through the public entry point.
  - `LearningTests.swift:73,85` count mock calls. `:236-301` assert prefilter failure reasons. `:382-388` pin the prompt string. Assert outcomes instead, and keep the "no model call" cost guards.
  - `SpeakerMergeTests.swift:65-67`, `EchoLagTests.swift:70-76`, `ClaudeReplyMarkdownTests.swift:25-32`, `TranscriptRenderTests.swift:103,120`, `RosterRulesTests.swift:92-98` and `ChunkCutterTests.swift:5-11` test helpers whose behaviour other tests already cover.
  - `SpeakerNamingTests.swift:12-21` and `MeetingMachineTests.swift:17-23` take shipped `Fixed` tuning, so any retune breaks algorithm tests. Pass explicit rules.
  - `PuffPixelsTests.swift:7,33-37`: magic floors and coordinates.
  - `test_fluid_vad.py:37-38` checks argv and call count.

- **Remove tests that can't fail.**
  - `InsightsTests.swift:83-89` (enum uniqueness).
  - `MeetingCodableTests.swift:63-67` (a fixture checking itself).
  - `MeetingWatchTests.swift:48-52` (calls a pure function twice and compares).
  - `MeetingMachineTests.swift:71-73`.
  - `test_core.py:53`.
  - Asserts that follow a full-equality assert: `HistoryEntryTests.swift:26-27`, `ProcessOwnerTests.swift:39` and `TrackWriterTests.swift:39`.

- **Fix flakes and skips.**
  - `CameraCompositorTests.swift:41` really sleeps. Inject the fade clock.
  - `PinnedDownloadTests.swift:79-83` polls, and `:15-16` shares static state.
  - `DayLineTests.swift:50-55` uses `Date.now` and `Calendar.current`.
  - `ScreenContextTests.swift:74-83` and `LearningTests.swift:172,190` depend on the machine's dictionary. That goes away once there is one known-word oracle.
  - `SpokenSentenceEndsTests.swift:5-8` goes through a singleton.
  - `SpeakerAssignTests.swift:77,114-169` depend on `NSFullUserName()`.
  - `LearningTests.swift:402-423` never runs in CI and leaves a `print` behind.
  - Python: `test_pipeline.py:20,35,75,94,100`, `test_fluid_vad.py:25` and `test_systems.py:36` leak env, argv and monkeypatches between tests.

- **Merge duplicate tests and move misplaced ones.**
  - Pairs that test the same behaviour:
    - `TextSearchTests.swift:64` and `TranscriptFindTests.swift:5`.
    - `ListSelectionTests.swift:79-94` and `HistoryEntryTests.swift:17`.
    - `CustomWordMatcherTests.swift:152-158` and `SpeechModelTests.swift:52-57`.
    - `EchoLagTests.swift:70-76` and `InsightsTests.swift:273-282` (two percentile implementations).
    - `ProcessOwnerTests` and `MeetingWatchTests`.
    - `MeetingInsightsTests.swift:35` and `MCPTests.swift:324`.
  - Repeats within one file: `MeetingMachineTests.swift:137/450` and `:235/306`, `MeetingWatchTests.swift:28,36,43`, and `test_review_server.py:17-22`.
  - **The tests pin both "is this the user" rules:** `SpeakerAssignTests.swift:70-75` against `SpeakerCountTests.swift:68-76` and `RoomVoicesTests.swift:13-16`. One rule and one test should replace them.
  - Misplaced:
    - `QuestionSpotterTests.swift:77-160`.
    - `TranscriptRenderTests.swift:79,124,220,226`.
    - `VoiceNamesTests.swift:14`.
    - `CustomWordMatcherTests.swift:152-174`.
    - `PostProcessorTests.swift:59-74`.

- **Share test helpers.**
  - The same helper is written more than once:
    - A UTC calendar three times.
    - A temp dir three times.
    - A seeded random generator twice.
    - Word, speaker, paragraph and span builders in many files.
    - `info()` twice.
    - Throwaway defaults twice.
    - Full `HistoryEntry(...)` construction six times.
    - The golden front matter five times in `TranscriptRenderTests`.
    - The JSON-RPC result decoding four times in `MCPTests`.
    - Python setUp copied across files.
  - Six files mutate `MeetingFixtures.example` instead of calling `MeetingFixtures.meeting()`.

- **Add tests for what decides what gets pasted or merged.**
  - Nothing tests these guards: `PostProcessor.looksLikeRewrite`, `ModelText.stripThinkBlock`, `ModelText.stripTrailingFullStop` (for "...", "e.g." and "?").
  - `MeetingMerge.joinedNames`, and the untested parts of `joined` and `previous`.
  - `RosterRules.read`.
  - Python: `apply_decisions` overlap skipping and the `NOTE_MAX` cut.
