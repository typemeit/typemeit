# Meetings: data, Claude, questions, Insights, MCP

Each fix sits above the problems it solves.

- **Split `Meeting.swift` into a shared on-disk core and app extensions.** The core holds the Codable schema, `durationLabel`, `zone`, track file names (raw, kept, merged), `youName`/`themName` and `countsAsMine` (`isDone && recordedHere`). App-only members move out, and `MeetingNames` gets its own file. The MCP target then drops `Shims.swift`, `SpeakerNaming.swift` and most of `TranscriptRender`.
  - `Meeting.swift:17,270-280,292-304`: app-only members (`framesPerMs`, `onlyYourSide`, `TrackWords`, `SpeakerSegment`, audio helpers) force `MCP/Shims.swift` to redeclare `AudioCapture`, `Fixed`, `Log` and `Transcriber.Word` with copied values.
  - `project.yml`: the MCP compiles all of `SpeakerNaming.swift` for the `MeetingNames` struct.
  - `TranscriptRender.swift:277-329`: page view logic sits in the renderer, which the MCP compiles for `timestamp(ms:)`.
  - Track names: `.caf` is a literal in 8 places, `.merged.caf` twice (`MeetingMerge.swift:110,124`).
  - Six copies of "You" (see the capture file). `MeetingSummary.swift:148,150`: the prompt assumes the user is still called "You", but `MeetingTurns.swift:17` passes the renamed name.
  - An unknown time zone falls back to UTC at `TranscriptRender.swift:204`, but to `.current` at `MeetingStore.swift:127,218,313` and `MeetingFolder.swift:169`, so the folder name and `started:` can disagree.
  - The "counts as mine" filter: `MeetingInsights.swift:21` and `InsightsTab.swift:33` use `isDone && recordedHere`, while `MCP/Tools.swift:170` uses `recordedHere` only, so the MCP's totals count meetings that were never transcribed.
  - `Store.swift:6` and `HistoryEntry.swift:41`: the history model calls Insights and embeds `Meeting.Question`.

- **One `MeetingText` module for every textual form of a meeting.** It owns the front-matter writer and reader (one `quoted`, one date formatter), the `**name** · m:ss` heading format with its parser, the duration-label parser, plain text and the byte cutter.
  - **Bug:** front matter is built at `TranscriptRender.swift:226-246` and `MeetingShare.swift:33-44` with two different `quoted()` (`:193` vs `:57`). A title with a newline breaks `transcript.md` but not the `.tmi` file.
  - `MeetingShare.swift:170` parses the literal `"** · "` that `TranscriptRender.swift:340` writes.
  - `ClaudeCheck.swift:63-67` checks a heading shape real transcripts don't use.
  - `MeetingFolder.swift:71-87` re-parses `Meeting.durationLabel` (`Meeting.swift:22-30`).
  - The date formatter is set up at `MeetingFolder.swift:14-21`, `TranscriptRender.swift:205-209`, `MeetingShare.swift:156-159` and `MCP/Protocol.swift:445`.
  - The `MeetingFolder.name(...)` call is unpacked at `MeetingStore.swift:127,218,313` and `MeetingFolder.swift:169`.
  - `MeetingFolder.swift:54-67` and `MCP/Tools.swift:339-356` both cut text to N UTF-8 bytes.
  - `MeetingFolder.swift:183-189` and `MCP/Tools.swift:316-333` both list readable meeting folders.
  - "Channel and workspace, else Meet code" is decided at `TranscriptRender.swift:239-244` and `MCP/Tools.swift:101-104`.
  - Plain-text rendering is written three times: `Meeting.swift:283-285` (ignores asides), `MeetingSummary.swift:60` and `TranscriptRender.paragraphs`.
  - `MCP/Tools.swift:125`: the MCP serves `transcript.md`, which `Meeting.swift:4` calls "never read". The rendering is the MCP's API.

- **One `ClaudeProfile` (folder, model, tools, permission mode, system prompt), one process runner, one stream decoder, and `ClaudeLive.run` owning the call order.**
  - The five settings are passed by hand at `MeetingCoordinator.swift:853,1096`, `ClaudeCheck.swift:86,226` and `ClaudeRun.swift:182,206,217`.
  - Stream-json is parsed three ways: `ClaudeRun.swift:322-366`, `ClaudeStream.swift:19-50` and `ClaudeModels.swift:274-285`. Reading lines from stdout is written twice (`ClaudeRun.swift:280`, `ClaudeModels.swift:258`).
  - `ClaudeCheck.swift:182-200` and `MCPConnect.swift:44-56` reimplement `ClaudeRun.command`.
  - `QuestionCheck.swift:136,164-172` copies the haiku model and the flag set but leaves out `MAX_THINKING_TOKENS=0`.
  - The "not installed" text is at `MeetingCoordinator.swift:865,1134` and `ClaudeCheck.swift:143,228`, beside `ClaudeRun.installPage`.
  - The order start → answer → finish → calls is written by hand at `MeetingCoordinator.swift:870,1145` and `ClaudeCheck.swift:232`. The run id convention is shared with `DictationPage.swift:94`.
  - `ClaudeCheck.swift:18-24`: `Conditions` leaves out the system prompt, so editing it (including through the MCP) leaves a stale pass. `:57,69` stores the pass under a raw key, and `:70` writes nil if encoding fails.
  - `ClaudeCheck.swift:85-91` and `ClaudeDesktop.swift:173,191,196` read `Settings.shared` and `MeetingStore.shared`.
  - `ClaudeStream.swift:12,28` returns the UI type `SquareClaudeLine`, which `ClaudeLive.swift:141` converts back into `Meeting.ToolCall`. `ClaudeRunOutput.swift:132` `Kept` mirrors `HookRun` and `Question`, and every call site re-packs them.
  - `ClaudeStream.swift:31` hides `ToolSearch` with a one-value `if`. `:79-81` strips only the meeting reminder, not `MCPTools.dictationReminder`.
  - `ClaudeRun.swift:50-63` repeats a sentence across two prompts. `:301` rebuilds the logs path from `DebugLog.swift:12`. `:13` `costUSD` is never shown. `:94` uses `Sandbox.isActive` where it should use the store-build flag.
  - `ClaudeCheck.swift:131` keeps install-path knowledge apart from `ClaudeRun.swift:85`.

- **A shared `MCPCatalog.swift`** compiled into the app and the MCP, holding tool names, help text, defaults keys (hooks included) and reminder lines. `MCPSetup` moves out of SettingsUI and becomes the one answer to "is our server registered".
  - Four tool-name lists: `MCPConnect.swift:99-112`, `MCP/Protocol.swift:187-279`, the switch at `:325-410`, and `ClaudeDesktop.swift:179`.
  - Defaults keys live in two homes (`MCPDefaults.swift`, `MeetingHook.swift:8`). The KVO at `Settings.swift:413-415` relies on property names matching the key strings.
  - `MCP/Tools.swift:202,212` quote settings labels defined in `OnePageSettings.swift`.
  - `ClaudeDesktop.swift:210-215` reads `~/.claude.json`, and `MCPConnect.swift:27-31` asks `claude mcp get`. The two can disagree.
  - `MCPConnect.swift:6-57`: non-UI logic in a view file, which `ClaudeDesktop.swift` depends on.
  - `MCP/Protocol.swift:127-131` is a second line encoder beside `StoredJSON.lineEncoder`. `:44-51` and `:87-92` copy the number encoding.
  - **Bug:**
    - `MCP/Protocol.swift:61`: `Int(Double)` traps on huge input.
    - `:445-456`: a date-only `to` leaves out that day.
  - `MCP/Protocol.swift:138` has defaults that exist only for tests. `MCP/main.swift:58-88` walks a host bundle id for an embedding that is not built.
  - **Bug:** `MeetingHook.swift:18,22` reads an undecodable blob as `[]`, and `MCP/Tools.swift:226` then writes over the user's hooks.

- **Delete the retired live question spotter.**
  - `QuestionSpotter.swift:85-158` (`SentenceSplitter`, `QuestionRule`, `QuestionDeduper`, `LiveWord`), `QuestionCheck.swift:126-178` and `QuestionLog.swift:222-239` are used only by tests. `question-log.jsonl` is never read.
  - `QuestionSpotter.swift:13-22`: `track`, `end` and `addressed` are fixed by the only constructor. `:14` is a parallel enum of `Track.Role`.
  - `QuestionLog.swift:185-192` and `Meeting.Question.Outcome` are mapped by hand (`MeetingCoordinator.swift:1008`).
  - `QuestionLog.swift:209-219` uses `try?` at every step of the append.

- **Make the store honest.** `save` renames and unions itself. The live ids, the limit and the deletion side effects are passed in. The machinery for a chosen folder goes.
  - `MeetingStore.swift:124`: callers must call `renameFolderIfNeeded` after `save` (`MeetingCoordinator.swift:719,808`).
  - `MeetingCoordinator.swift:902,1200` and `MeetingStore.swift:90-95` both union questions and hook runs. `Meeting.swift:156` dedupes by equality and `:178` by id.
  - `MeetingStore.swift:165-170,183` reaches into `MeetingCoordinator`, `RecordingPlayer`, `VoiceLibrary` and `Settings` singletons.
  - `MeetingStore.swift:20-22,44,214,247`: `folderAvailable` and `parentResolves` handle an ejected disk, but the root is fixed under Application Support. The Info.plist "folder you chose" strings are left over from the same idea.
  - `MeetingMerge.swift:46-80` resets fields one by one, and a merge keeps `speakers` while clearing `paragraphs`. `:93-94`: `rank` mirrors `MeetingNames.Source` with a `!`.
  - Dead or pass-through: `MeetingFolder.swift:223` `isInICloudDrive`, `:128-139` (used only by tests), `MeetingStore.swift:176` `deleteAll`, `Meeting.swift:258` `speakerCount`, `Meeting.swift:12` `dataReminder`, `MeetingStore.swift:142` `assign`, and `MCP/Tools.swift:322`.
  - Swallowed errors:
    - `MeetingStore.swift:158,272`.
    - `MeetingFolder.swift:246`.
    - `ClaudeRun.swift:315`.
  - `MeetingFolder.swift:233-248`: the doc says AAC but the code writes Opus, and an empty `do {}` block does nothing. `MeetingStore.swift:149` has a doc on the wrong function.
  - `TranscriptFind.swift` is used only by `MeetingPage.swift:178`, which maps hits back to rows itself. `MeetingFingerprint.swift` is split over three folders.

- **Insights: one app key and one median.**
  - `Insights.swift:380-399` writes the per-app key twice (one trims, one doesn't).
  - `MeetingInsights.swift:34` is a lower median, while `Insights.swift:107-141` interpolates.
  - `MeetingInsights.swift:26,36` counts by display name, while `Insights.swift:396` counts by bundle id.
  - `Category.swift:35-46`: names are capitalised, and the only caller lowercases them.
  - `Category.swift:70-217,338-368`: about 30 Windows `.exe` rules and `ScalarText` preserve parity with a Rust original that is no longer in the repo.

- Comments: about 12 only restate the code (for example `MeetingFingerprint.swift:15,56`, `Insights.swift:209`).
