# UI: DesignSystem, SettingsUI, Overlay, Onboarding, Camera, gallery

Each fix sits above the problems it solves.

- **Design data lives in the design system, and the design system imports no feature.** `PuffView` with `Puff.metal`, the menu-bar mark, `ClaudeReplyMarkdown`, and `CloudColor`/`CloudPosition`/`CloudChoice` move in, with one `tint(choice, backdrop:, scheme:)`. `SquareClaudeLine` moves out to the stream parser. Parts take plain values, not feature types.
  - `SquareChrome.swift:30` uses `MenuBarIconRenderer.mark`, and `:119,242` use `PuffView`. `SquareFingerprint.swift:14,19,112` uses `Meetings/MeetingFingerprint`. `ClaudeMarkdown.swift:16` uses `Meetings/ClaudeReplyMarkdown`.
  - `SquarePalette.swift:6` defines `CloudChoice`, which `Settings.swift:93` uses, so app state depends on the design system.
  - The cloud tint is mapped four ways: `SquarePalette.swift:42-64` (greys 0.34/0.85), `CloudView.swift:104-113` (reads `Settings.shared`), `CameraFeed.swift:123` (pure black/white) and `Settings.cloudChoice`.
  - `SquareTabs.swift:55`: the parser (`ClaudeStream.swift:12`, `ClaudeLive.swift:15`) produces a design-system type. `SquareTabs.swift:147` builds `claude --resume`, as `TranscriptRender.swift:85` does.
  - Feature copy inside parts: `SquareChips.swift:59` (dictionary words), `SquarePalette.swift:101,110` (screen recording), `SquareRows.swift:250` (meeting band).
  - `project.yml:349-370` hand-lists every app file the gallery target pulls in.
  - `SquareKeys.swift:45`: the static `listeningChanged` hook is set by `Pipeline.swift:40`. Pass it through the environment.
  - `SquareFoundations.swift:133,187` stores its own appearance enum under Settings' `"appearance"` key, with different values.
  - Camera token copies: `CameraProvider.swift:198,203` and `CameraAnswerCard.swift:18`. `CameraCompositor.swift:80,239` borrows `ScreenSampler` luminance from Overlay.

- **Pill states are data.** One pure mapping from state to content (mark, message, actions) feeds PillView, the gallery specimen and the meetings first-run. AnswerPill is a SquarePrompt variant. `dismiss(then:)` replaces the `closeNow` ritual. A per-case table replaces three parallel switches.
  - `SquarePrompt.swift:169-229` re-types every pill message from `PillView.swift:56-251`. `MeetingsTab.swift:637` is a third copy of the record prompt.
  - `SquarePrompt.swift:301-345`: the ask specimen is not the shipped `AnswerPill.swift` layout.
  - `AnswerPill.swift:21-33,164-169` copies SquarePrompt's metrics and quiet icon. Pill widths live in three files (`OverlayModel.swift:113`, `AnswerPill.swift:21`, `SquarePrompt.swift:345`).
  - `PillView.swift:57,66,68…`: about 13 sites set `model.closeNow = true` before a callback.
  - `OverlayModel.swift:52-65,102-110`: `isMeeting`, `isStanding` and `presentation` are parallel lists, and `isMeeting` defaults to `false`.
  - `OverlayModel.swift:128-167`: about 25 optional callbacks wired after init. A missing one silently does nothing.
  - `AnswerPill.swift:12`: `.queued` is reached only by a probe.

- **The overlay owns the cloud geometry.** One function gives each position as a fraction of the screen, and the picker draws it.
  - `SquareMenu.swift:102-110` re-encodes `OverlayPanel.swift:98-103`. `SquareMenu.swift:69-71` uses `NSScreen.main`, while the overlay uses the screen under the mouse.
  - `OverlayPanel.swift:97,200,209` reads and writes `Settings.shared` directly.

- **Settings applies its own side effects** (shared with the dictation-core fix). `KeepLimit` becomes a model type.
  - `OnePageSettings.swift:218,291,417-427,486-510,731,735`: appearance, launch at login, updates, learn voices, keep limits, the camera and the Claude Code check only take effect because this view calls a hook. Changes from the MCP or elsewhere never apply them.
  - `OnePageSettings.swift:718-723` keeps the microphone name in step with the UID.
  - `OnePageSettings.swift:23-56`: the KeepLimit sentinels (0, −1) are reinterpreted at `Pipeline.swift:258`, `MeetingStore.swift:183` and `OnePageSettings.swift:454`.

- **A `SquareWizard` part and one permission-request helper.**
  - `CameraSetupView.swift:14-58,164-185` copies the onboarding wizard (`OnboardingView.swift:19-81,314-338`): the header, dots, 1 s poll, `advanceWhenSettled`, first-unsatisfied step and the debug override.
  - `OnboardingView.swift:287-338` decides whether a step is satisfied in three places.
  - `OnboardingView.swift:221,275` sleeps 1.5 s and checks `isActive` to guess "no prompt". The block is written twice, and the AX options twice (`:125,270`).
  - Camera readiness is turned into copy twice: `CameraSetupView.swift:132-150` and `OnePageSettings.swift:781-801`. `CameraSetupView.swift:73` and `CameraHost.swift:57` copy the instruction.
  - Apple Intelligence availability is polled and mapped three times: `OnePageSettings.swift:95,701`, `DictionaryTab.swift:16`, `OnboardingView.swift:38,164,293`, with different wording.
  - `OnePageSettings.swift:677-691` requests screen recording twice.

- **One labels module** for dates, durations, milliseconds, place names and `~` paths.
  - Five duration formats: `MeetingsTab.swift:314`, `Meeting.swift:22`, `InsightsTab.swift:212,226`, `LengthInSeconds.swift`, and `DictationPage.swift:180` (no space before "ms").
  - `MeetingPage.swift:199` and `DictationPage.swift:40` pass different audio-length formats to the same confirm, whose doc promises one.
  - Date labels live in `HistoryTab.swift:331-356`, are re-typed at `MeetingsTab.swift:399`, `MeetingPage.swift:286,332` and `DictationPage.swift:159`, and must match `Insights.swift:406` (`InsightsTab.swift:327,365`).
  - The place name has four versions: `SettingsView.swift:141`, `MeetingsTab.swift:252,352` and `MeetingPage.swift:570`.
  - Elapsed time is formatted two ways (`SettingsView.swift:142`, `MeetingsTab.swift:353`).
  - `~` paths: `OnePageSettings.swift:803,819` and `MeetingPage.swift:649`.
  - "summarising" vs "summarising…": `MeetingsTab.swift:684,507`.

- **Shared list parts.** A `ListFilters` value with `WhenFilter` in its own file, `SelectBoxColumn`, `CopyButton` and `Disclosure`.
  - `HistoryTab.swift:5-69`: `WhenFilter` and `TimeOfDayWindow` are shared but live in HistoryTab. Three tabs re-declare the filter state and its reset (`HistoryTab.swift:172,251`, `MeetingsTab.swift:54,160,223`, `InsightsTab.swift:97`). `InsightsTab.swift:22,28,96,114` rebuilds the filter four times per draw.
  - The select column is written at `HistoryTab.swift:408` and `MeetingsTab.swift:392`.
  - Copy with a check is written three times (`HistoryTab.swift:221`, `RecordingPageParts.swift:183`, `PillView`).
  - The fold with a chevron is written three times (`SquareTabs.swift:113`, `DictationPage.swift:112`, `OnePageSettings.swift:233`). `SpeakerNames.swift:72-100` re-implements `SquareMenuLine`.
  - `OnePageSettings.swift:361-372,515-543` rebuild `SquareSettingsRow` by hand. `MeetingsTab.swift:632` and `MeetingPage.swift:56,325` copy display3 tokens.
  - Cursor push and pop is written five times, and only one copy is balanced (`CloudView.swift:41-43` pops without pushing).
  - Hidden-but-kept modifiers: `SettingsView.swift:127` and `HistoryTab.swift:162`.

- **Meeting domain logic leaves the views, and the store owns word and audio operations.**
  - `MeetingsTab.swift:496-545`: `MeetingPhase` and `MeetingState` live in a view. `:531` `hasChips` must mirror `:555-579`.
  - `MeetingsTab.swift:28,67` and `MeetingPage.swift:18,362` each track "pausing" themselves.
  - `MeetingPage.swift:656-668` defines an extension that MeetingsTab uses.
  - `MeetingPage.swift:150-159,314-318`: two rename paths, and only one closes the field.
  - `MeetingPage.swift:778` copies the question header from `DictationPage.swift:83`. `:789` invents a run id.
  - Stop the player before deleting: `MeetingPage.swift:202,207` and `DictationPage.swift:43,48`.
  - Forgetting or adding a word takes two calls each time: `DictionaryTab.swift:39,76` and `DictationPage.swift:386,401`. Only one runs the check. `DictionaryTab.swift:66` parses "heard = word" in the view.

- **Typed navigation instead of `AppState` mailboxes** (shared with the open-settings fix in the meetings file).
  - `SettingsView.swift:64,165-174`, `HistoryTab.swift:170-188` and `MeetingsTab.swift:52-75`: the reveal mailboxes are set elsewhere and cleared by views.
  - `AppState.sidebarClicks` doubles as a reset signal (`SettingsView.swift:86`, `HistoryTab.swift:172`, `MeetingsTab.swift:54`).
  - `SettingsView.swift:72-75` waits 400 ms before keeping history.

- **Specimens become interactive, and the surplus goes.**
  - `SquarePalette.swift:141`, `SquareChrome.swift:337,354`: specimens pin states you reach by using the part, against CLAUDE.md.
  - Dead or unused:
    - `Square.swift:68,194` `SquarePose` and `pose:`.
    - `SquareKeys.swift:52` `listening:`.
    - `PillView.swift:4` `VisualEffect`.
    - `PuffView.swift:16-26` (four parameters), `:135` `disperse`.
    - `CloudView.swift:70` `t`.
  - `SquareChrome.swift:171-185` keys the hover animation by asset names, parallel to `SettingsTab.icon`, with a one-value `if`.
  - `PuffView.swift:90-93` repeats the shader's argument list. `OverlayPanel.swift:48` swallows a compile failure with `try?`. Smootherstep is written four times.
  - Raw key codes: `SquareKeys.swift:107,109` and `SquarePopover.swift:136`. `SquareButton.swift:77,137` duplicates the wash logic.
  - `SquareFoundations.swift:146-180`: the gallery list is updated by hand.
  - `DesignSystemGallery/LiveClaude.swift:39-99` copies the hook instructions, the CLI path, the meetings path and a line splitter, and a launch failure leaves it "running" forever.
  - Reduce motion is read once into `@State` (`CloudView.swift:13`, `PuffView.swift:59`).

- **Camera.**
  - `CameraIDs.swift:9` copies `project.yml:278`.
  - "The second stream" is a convention shared by `CameraProvider.swift:77` and `CameraSink.swift:31`.
  - `CameraProvider.swift:154` retries with a 10 ms `asyncAfter`.
  - `CameraInstaller.swift:101` treats "after reboot" as added.
  - `CameraSink.swift:21` and `CameraFeed.swift:159`: the "our camera" test is written twice.
  - `CameraFeed.swift:21,78` polls the singletons every 500 ms. `:104,113` gate on a debug flag. `:123` and `CameraAnswerCard.swift:25` share the magic number 100.

- **Copy rules (CLAUDE.md).**
  - `help:` carries state or a fix: `OnboardingView.swift:131,157,161,212` and `UpgradeView.swift:71`.
  - Captions give instructions or use full stops: `OnboardingView.swift:240` and `OnePageSettings.swift:154,434,787,788,797`.
  - `OnePageSettings.swift:206`: help runs to a paragraph.
  - `CloudView.swift:44`: capitalised tooltips.
  - `OnePageSettings.swift:346`: hard-coded "space".

- Comments: about 15 only restate the code (for example `SquareRows.swift:94`, `OverlayPanel.swift:77`, `CameraFeed.swift:15`). Stray or misplaced docs: `SquareChips.swift:99`, `SquarePrompt.swift:101`, `InsightsTab.swift:12`, `MeetingPage.swift:4,258,588`.
