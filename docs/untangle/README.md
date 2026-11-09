# Untangle: decision log

This is steps 2–3 of the untangle-codebase skill (`.claude/skills/untangle-codebase`). The log comes before any code changes, because this session can't build or run the Swift app. Comments and Tests are both in scope.

The area files list every problem with `path:line`, each under the fix that solves it:

- [area-meetings-capture.md](area-meetings-capture.md): recording, capture, transcription, speakers
- [area-meetings-data.md](area-meetings-data.md): the meeting model, text forms, Claude, MCP, Insights
- [area-dictation-core.md](area-dictation-core.md): top-level `TypeMeIt/*.swift`, `Learning/`
- [area-ui.md](area-ui.md): DesignSystem, SettingsUI, Overlay, Onboarding, Camera
- [area-tests.md](area-tests.md): the test suite

About 450 problems in all.

Below is the redesign: the few changes behind most of them, as if the app had known today's requirements from the start.

## Starting point

- 33k lines of app Swift. `Settings.swift` has 53 dependents and `Meeting.swift` has 44.
- `MeetingCoordinator` is 1306 lines and depends on 40 files. `Pipeline` depends on 39.
- 177 `try?`, 55 sleeps and 11 `asyncAfter`, 58 `Settings.shared`.
- The design system depends on feature code in 6 places.
- The MCP target compiles app files and patches the gaps with copied shims.

## The layers everything should fit

Each layer may use only the layers above it.

1. **Foundations.** Pure code that changes least and imports no app state:
   - `Lexicon`: filler words, number words, tokenizer, match key
   - `Labels`: dates, durations, place names, paths
   - `Intervals`: overlap, talk time, ordering, percentiles
   - `CoreAudioDevice`: device lookup and the host clock
   - `BuildInfo` and `LaunchArgs`
2. **Models.** Stored shapes and their on-disk text:
   - the `Meeting` core (shared with the MCP)
   - `MeetingText`, every textual form of a meeting
   - `HistoryEntry`
   - `Settings`, as stored values only
   - `MCPCatalog`
   - `SpeakerIdentity`
3. **Features**, each with its own tuning constants: dictation (`Pipeline`, `PostProcessor`, the dictionary), meetings (recorder, queue, transcriber, speakers), Claude (one `ClaudeProfile`, one runner), Learning, Insights.
4. **Presentation:**
   - the design system, which imports Foundations only
   - `ToastPresenter`, `Navigator`, Overlay
   - SettingsUI
   - `SettingsEffects`, the one observer that applies a changed setting

Today each layer reaches down into the ones below it: Settings imports Updates, ClaudeRun and the design system, and the design system imports meeting files. That is why one meeting tweak recompiles 53 files and why the MCP needs `Shims.swift`.

## The fixes, ranked by how many problems each removes

1. **Settings stores values, and nothing else.**
   - `Fixed` splits into per-feature tuning, so about 75 meeting constants go to Meetings.
   - Every side effect moves into one `SettingsEffects` observer: appearance, launch at login, updater, prune, debug log, microphone name, camera, the Claude check.
   - `CloudChoice`, `KeepLimit` and the microphone lookup move to their owners.
   - Solves about 40 problems in dictation-core and UI, the effects that run only while the settings page is open, and the change-of-a-setting-from-the-MCP case.

2. **One presenter for everything that pops up or navigates.**
   - `ToastPresenter` owns the overlay countdown and queue for dictation, meetings and updates.
   - `Navigator.show(.settings(tab, reveal))` replaces the `AppState` mailboxes and the `openSettings` notification.
   - Shortcuts and AppState observe `Pipeline.phase` instead of being sent copies.
   - Pill states become a data table that PillView and the gallery both render.
   - Solves the two toast tasks on one overlay, the 5 s retry timers in Updates, about 10 `setPhase` mirrors, 7 open-settings copies, 13 `closeNow` sites and the drift of pill copy into the specimen.

3. **The meeting core is a small shared model, and every text form of it comes from one place.**
   - The MCP compiles only `Meeting` core, `MeetingText` and `MCPCatalog`. `Shims.swift` goes, and so does SpeakerNaming in the MCP.
   - Track names, "You" and "Room", the time-zone fallback and "counts as mine" are each defined once.
   - Solves about 35 problems, including two real bugs: a newline in a title breaks the front matter, and `meeting_stats` counts untranscribed meetings.

4. **`MeetingCoordinator` splits into recorder, queue and Ask Claude.**
   - The recorder owns applying its result to the Meeting.
   - The queue is one type that publishes when a pass ends: no 1 s tick, no `queued` mirror, and deleting while live is an explicit argument.
   - Ask Claude takes one `ClaudeProfile`, and `ClaudeLive.run` owns the call order.
   - Solves about 45 problems, including the rejoin progress written into the wrong pass, two delete paths, and a stale Claude check after a system-prompt edit.

5. **One meaning, one definition, in Foundations.**
   - The `Lexicon` replaces five filler lists, four ordinal lists, two tokenizers, two match keys and two English dictionaries.
   - `Intervals` replaces six overlap helpers, four ordering loops and three word normalisers.
   - `Labels` replaces five duration formats and four place-name versions.
   - `CoreAudioDevice` replaces three device enumerations and the dictation-to-meetings dependency.
   - One `TrackReader` replaces four file readers.

6. **Pure steps take their inputs.**
   - The transcriber, speaker assignment, the store and the Claude check receive settings, the user's name, live ids and limits as arguments, instead of reading `Settings.shared`, `NSFullUserName()` or other singletons.
   - Solves probes writing into the real voice library, tests that depend on the account running them, and the store depending on the coordinator.

7. **Delete what no longer has a reason to change.**
   - The retired live question spotter.
   - The ejected-disk folder machinery.
   - The Windows `.exe` category rules.
   - `SquarePose`.
   - Dead functions, listed per area.

8. **One dictation text path.** Clean-up off runs `PostProcessor.clean` with the model skipped, and one `Dictionary.match` serves the pipeline, meetings, the verifier and the eval.

## Bugs the redesign fixes along the way

- With clean-up off, writing styles, units and spelled letters silently stop applying (`Pipeline.swift:338`).
- There are three "is this the user" rules. A user listed under a short form of their name counts as an extra far-end voice (`SpeakerCount.swift:335`, `RoomVoices.swift:227`).
- A title with a newline breaks `transcript.md` front matter (`TranscriptRender.swift:193`).
- `meeting_stats` counts untranscribed meetings (`MCP/Tools.swift:170`).
- A hooks blob that fails to decode reads as empty, and the MCP's add-hook then overwrites the user's hooks (`MeetingHook.swift:18`).
- Rejoin progress is written into whichever pass is running (`MeetingCoordinator.swift:736`).
- A capture conversion error drops frames with no gap, so meeting time drifts (`MeetingCapture.swift:461`).
- The MCP traps on `limit: 1e300`, and a date-only `to` leaves out that day (`MCP/Protocol.swift:61,445`).
- `QuestionCheck` runs without `MAX_THINKING_TOKENS=0`. Moot once it is deleted.
- `CloudView` pops a cursor it never pushed.

## Separate from the refactor, and more urgent: personal data in the public repo

The test audit found what looks like real data already in `main`:

- The owner's name in many test fixtures.
- A captured Slack workspace and channel, in `RosterRulesTests` and in comments in `RosterRules.swift`.
- A real meeting tab title.
- Real-looking full names.
- Verbatim words from dated calls (`TranscriptMergeTests`, `EchoFoldTests`).

CLAUDE.md says these must be invented fixtures. Scrubbing them is a fixture change, not a refactor, and removing them from history means rewriting or recreating the repo, so the owner has to decide.

## Order of work

Every step needs a Mac build and `xcodebuild test` before the next. A cloud session can only write the change.

1. Scrub fixtures. Delete dead code and the retired spotter. Mechanical, low risk.
2. Foundations: `Lexicon`, `Intervals`, `Labels`, `CoreAudioDevice`, `BuildInfo`. Callers switch one by one.
3. The meeting core and `MeetingText`, then the MCP target loses its shims.
4. Settings split and `SettingsEffects`.
5. `ToastPresenter`, `Navigator`, phase observation, the pill table.
6. `MeetingCoordinator` split, the queue type, `ClaudeProfile`.
7. Design system dependency flips, the wizard, list parts.
8. Comments pass.
9. Tests pass, last: remove self-checking and can't-fail tests, unpin tuning, add the guard tests listed in area-tests.md.

Before declaring done, run the skill's step 5: re-audit with subagents until nothing worth fixing is left, then check behaviour against `make eval` and the test suite on a Mac.
