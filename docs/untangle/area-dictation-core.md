# Dictation core: top-level `TypeMeIt/*.swift` and `Learning/`

Each fix sits above the problems it solves.

- **Split `Settings.swift` into stored settings, constants and side effects.** `Fixed` moves into per-feature constants. `Settings` becomes a plain stored model that imports no feature. Every side effect of a setting runs in one observer, started once at launch, not in UI bindings.
  - `Settings.swift:425-651`: `Fixed` holds about 75 meeting constants, paste and unmute timings, and the learning denylist, in the file 53 others depend on.
  - `Settings.swift:93,297,302,322,325,329`: the model depends on `CloudChoice` (from the design system), `Updates.isDevBuild`, `Sandbox`, `ClaudeRun.defaultModel`, `MeetingHook` and `ScreenSampler.Backdrop`.
  - `Settings.swift:265-275`: `connectedMicrophoneUID` does a CoreAudio lookup and a DebugLog write inside the settings model.
  - `Settings.swift:61-63`: `matchedWords` mixes matcher policy (built-in words) into settings. `DictionaryTab.swift:76` reads `customWords` instead.
  - Some side effects live in Settings' `didSet` (`:45-56,178-184`). Others must be triggered by the UI that writes the value: `OnePageSettings.swift:488,494,501,509,731,735` (appearance, launch at login, updater, history prune, meeting prune).
  - `Settings.swift:181,233` pushes `debugLogs` into the `DebugLog.enabled` global, and `MeetingProbes.swift` writes the same global 12 times behind Settings' back. `TypeMeItApp.swift:266,333` touches `_ = Settings.shared` first, just for that side effect.
  - `Settings.swift:41-232`: each setting is written in four places (property, init load, `Stored` key, and the key list in `SettingsTests.swift:180`).
  - `Settings.swift:90` `cloudMatchesBackdrop` is just `!cloudColorEnabled`.
  - `OutputMute.swift:15`: a key outside `Settings.Stored`. `MCPDefaults.swift:2` claims to hold the shared keys, but the hooks key is at `MeetingHook.swift:8`.

- **One phase, owned by Pipeline, and one toast presenter.** Shortcuts and AppState observe `Pipeline.phase` instead of getting copies. A `ToastPresenter` owns the overlay's countdown and queue for Pipeline, meetings and updates alike.
  - `Pipeline.swift:146,152,206,249,259,294,320,377`: every `phase` assignment must be followed by a matching `shortcuts.setPhase`. `TypeMeItApp.swift:399-408` mirrors the phase a third time.
  - `Pipeline.swift:12`: the `phase` didSet calls `Updates.shared.remind()`.
  - `Pipeline.swift:14` and `MeetingCoordinator.swift:120,952-983`: two toast tasks drive one overlay, and neither cancels the other.
  - `Updates.swift:185,242`: two 5 s polling timers wait for an idle pipeline or a free overlay. `Updates.swift:181-188,235-248` and `Pipeline.swift:12,67,468` depend on each other.
  - `Pipeline.swift:466-470`: `keepLearned()` also puts off update toasts.
  - `Learning/ToastTiming.swift:5`: general toast timing lives in Learning.
  - `Shortcuts.swift:209-214`: `.recordingStarted` must be emitted before `.pinned`.
  - Callers reach through `Pipeline.shared.shortcuts` (`TypeMeItApp.swift:163,166`, `MeetingCoordinator.swift:201`, `MenuBarClick.swift:23`).
  - `Pipeline.swift:141,64`: the pipeline opens windows and posts UI notifications itself.

- **One text lexicon.** Filler sounds, kept filler phrases, spoken punctuation, ordinals and number words, stop and function words, the match key, the word scalar and the tokenizer live in one file. The prompt interpolates its lists from it.
  - Five filler lists have drifted apart: `PostProcessor.swift:211,28`, `LocalCleanup.swift:13`, `WritingStyle.swift:132` and `Learning/Prefilter.swift:19`.
  - `PostProcessor.swift:317` `keptWords` must equal `WritingStyle.swift:73-85` `fillerPatterns` and the prompt at `:28`.
  - `PostProcessor.swift:259` `spokenPunctuation` runs parallel to `ModelText.swift:119-125` and the prompt at `:27`.
  - Ordinals are written four times (`WritingStyle.swift:125,128,131` and `Digits.swift:15`), and number words twice (`WritingStyle.swift:84`, `Digits.swift:7-21`).
  - `TokenDiff.swift:43` equals `LocalCleanup.swift:105`. `TokenDiff.swift:29` `matchKey` claims to equal `CustomWordMatcher.swift:224` `letters`, but it differs. `TokenDiff.swift:56` is re-implemented at `Insights.swift:205`.
  - `Prefilter.swift:26` `functionWords` runs parallel to `CustomWordMatcher.swift:106` `stopWords`.
  - `HistoryEntry.wordCount` (`Store.swift:6`) calls Insights, which calls TokenDiff, which calls ModelText, just to count words.
  - `CustomWordMatcher.swift:134,204,219` and `HeardWord.swift:12` use `LocalCleanup.Token` as their tokenizer.
  - `Digits.swift:40` and `WritingStyle` call each other. `WritingStyle.swift:272` is a pass-through.
  - `Digits.swift:74,100` writes the percent rule twice. `Digits.swift:75` overlaps `ClockTime.swift:13-44`.
  - `PostProcessor.swift:250` is a second sentence-capitaliser beside `WritingStyle.swift:104`.

- **One dictionary: one entry point for matching, one oracle for known words, one store.** One `Dictionary.match(words:)` picks the terms (built-ins plus aliases), the known-word check and the NaN handling, for the pipeline, the meetings, the verifier and the eval. Learned words and aliases move out of the history store, and one normaliser serves the input and the learner.
  - `VerifyCustomWord.swift:101-104` claims "the same matcher the live pipeline runs", but it has no known-word check, no built-ins and no aliases (`Pipeline.swift:311`). The doc at `:39-42` is stale.
  - `Learning/WordList.swift:33` uses `/usr/share/dict/words` while the matcher uses NSSpellChecker (`EnglishWord.swift:7`): two meanings of "known word".
  - `Learning.swift:48`: `normalizeWord` claims to match the Custom Words input, which only trims (`DictionaryTab.swift:67`, `Settings.swift:252`). `Prefilter.swift:12` `maxMeantChars` claims a limit that the input lacks.
  - `Learning.swift:13,26` and `Store.swift:9` are three copies of `{heard, meant}`. `Check.swift:90` repeats every case of `CorrectionKind` (`:11`).
  - `Store.swift:136-203`: the alias API lives in the history store.
  - `PostProcessor.swift:290-308` reimplements the matcher's sound matching.
  - `Transcriber.swift:100` and `MeetingTranscriber.swift:345` both turn NaN confidence into nil.
  - `ScreenContext.swift:160`: `unknownWords` is a dictionary helper, not screen reading.
  - Whether to learn is decided in three places: `ReadBack.swift:14,38`, `Pipeline.swift:380` and `LearningCoordinator.swift:14`.

- **One text path after transcription, whether clean-up is on or off.**
  - **Bug:** with clean-up off, `Pipeline.swift:338` uses a hand-built path that skips writing styles, units, currency and spelled letters, so styles silently stop working, and the claim at `PostProcessor.swift:116-119` (the eval scores what gets typed) is false.
  - `PostProcessor.swift:140,162` runs `joinSpelledLetters` twice, and `fuseTerms` runs three times (`:142,146,187`).
  - `PostProcessor.swift:98-100`: `prepare` must be called again with the same styles, or the warm session is silently thrown away.
  - `PostProcessor.swift:369` has a parameter that is always `PostProcessor.template`.

- **One CoreAudio device module (shared with meetings, see that file).**
  - Device enumeration is written at `AudioCheck.swift:74-80`, `AudioCapture.swift:296-304` and `MeetingCapture.swift:166-168`. The Bluetooth test is at `AudioCheck.swift:31` and `MeetingCapture.swift:160`. UID lookup is written twice in `AudioCheck.swift:68,169`.
  - `AudioCapture.swift:317` lists mics from AVCaptureDevice, while `Settings.swift:271` finds them by name among CoreAudio devices.
  - `AudioCapture.swift:61,71,114` and `RecordingArchive.swift:53` repeat the error domain literal, and code 1 means two things.
  - `Pipeline.swift:235` and `Transcriber.swift:166,178` use the literal `16000`.
  - `Pipeline.swift:129,242` has two 0.08 s unmute delays that belong to `OutputMute`. `OutputMute.swift:105-112` retries 12×.

- **`BuildInfo` and `LaunchArgs` in one place, and System Settings links out of `SecureInput`.**
  - `isDevBuild` is written at `Updates.swift:41,357` and `MenuBarIcon.swift:13`. `Updates.swift:350-355` copies the whole `State` enum for the store build.
  - `AudioCheck.swift:44` duplicates `DebugLog.swift:45` `writeHeader`.
  - Launch keys are scattered: `TypeMeItApp.swift:443,450`, `Sandbox.swift:13`, `MeetingCoordinator.swift:1207`, `OnboardingView.swift:331`, `CameraSetupView.swift:166` and `SquareFoundations.swift:184`. `TypeMeItApp.swift:445,452` waits with launch sleeps.
  - `SecureInput.swift:66-73` holds every deep link, for callers that have nothing to do with Secure Input.
  - `Store.swift:33`, `RecordingArchive.swift:9` and `ModelStore.swift:31` define paths outside `SupportPaths`.
  - `ModelStore.swift:14,20` repeats the hash. `:75,83` both set the version. `:54` has a parameter always passed `true`.
  - `HistoryEntry.swift:41` embeds `Meeting.Question` in the dictation record.

- **General helpers out of feature files, dead code out.**
  - Dead: `Pipeline.swift:432` `copyLastTranscript`, `Transcriber.swift:155` `transcribe(_:)`, `Shortcuts.swift:177` `uninstall` and `:33` `tapInstalled`.
  - Pass-throughs: `Pipeline.swift:111` `toggleRoom` and `:299` `elapsedMs`.
  - `CustomWordMatcher.swift:116` has an overload used only by a Scripts bench.
  - Three `trimming` extensions sit in Learning files. `Output.swift:323` holds `Duration.milliseconds`, which `ScreenContext.swift:39` re-derives.
  - Raw key codes: `Output.swift:39,105` and `Shortcuts.swift:57`, against `KeyCombo.swift:119`. `KeyCombo.swift:20-138` maps the four modifiers four times.
  - `Focus.swift:71-101` repeats `FocusedTextField.captureFrontmost`.
  - `Pipeline.swift:117` and `TypeMeItApp.swift:110` filter the same "last transcript".
  - `Output.swift:137-186`: the debug paste check depends on Learning internals.
  - `WindowDump.swift:26` writes into the published Meetings root.
  - `MenuBarIcon.swift:23` repeats layer names. `DebugLog.swift:13` repeats its path.
  - `askClaude && ClaudeRun.isAvailable` is re-tested at `MenuBarClick.swift:25`, `TypeMeItApp.swift:211` and `Pipeline.swift:347`.
  - Swallowed errors:
    - `Learning.swift:145-149`: a broken learner looks like nothing to learn.
    - `RecordingArchive.swift:17-27`: returns the name before a write that can fail.
    - `ScreenContext.swift:23,36,60`.
    - `Settings.swift:396,406`: a failed encode deletes the shortcut.
    - `WindowDump.swift:68`.
  - About 35 comments are stale or misplaced. Examples: `Settings.swift:146-152` (doc pile), `PostProcessor.swift:111-119` (two docstrings stacked), `Store.swift:151`, `ModelText.swift:6-14`, `Digits.swift:3-5` (stale "only caller").
