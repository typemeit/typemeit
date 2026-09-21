# A local MCP server for type me it

A plan for letting an agent on the same Mac — Claude Code, Claude Desktop,
Cowork — read the dictation history and insights, and later run a dictation and
the clean-up model, through a Model Context Protocol server shipped inside the
app bundle. Written September 2026; nothing below is built yet.

## Why

Everything the app knows is already on the machine and already in JSON:
`history.json` and `learned-words.json` in `Store.directory`, plus the
statistics `Insights` derives from them. Today the only way to see any of it is
the settings window. An agent working in a terminal has no way to ask "what did
I dictate into Slack this morning", to reuse a transcript it just watched the
user speak, or to hand text to the clean-up model the app already talks to.

The second half is the more interesting one: a `dictate` tool turns the app into
an input device for an agent — speak, get text back, nothing typed anywhere —
which is a different job from the Fn key pasting into the frontmost field.

## What the code already forces

Four constraints, each read out of the current sources rather than assumed.

**The store is memory, not the file.** `Store` (`TypeMeIt/Store.swift`) holds
both arrays in memory on the main actor and rewrites each file whole after every
change. A second process that writes `history.json` while the app runs has its
write erased by the next save. So: reads may go straight to the files, writes
must go through the running app. There is no middle option short of rewriting
`Store` around a database, which is not worth it for this.

**There are two support directories, sometimes three.** `Store.directory`
resolves `TYPEMEIT_SUPPORT_DIR` first, then
`~/Library/Application Support/TypeMeIt`. The dev build (`it.typeme.typemeit.dev`)
shares that path but has its own `UserDefaults` domain, and the App Store build
is sandboxed, so its copy lives under
`~/Library/Containers/it.typeme.typemeit/Data/…`. The server has to resolve the
same way the app does and say which install it is serving.

**The sandbox splits the feature in half.** `Sandbox.isActive` already gates
what the store build offers. Reading its container from an unsandboxed helper is
fine; having the sandboxed app listen on a socket the helper can reach is
another matter. Phase 1 (read-only) works for both builds. Phase 2 (live
actions) targets the DMG build, and the store build keeps the read-only tools.

**"Nothing leaves the computer" is a promise this can break.** stdio inherits
the user's own permissions, so any agent the user runs can read every
transcript, window title and app name in the history. That is the point of the
feature and also its risk. It ships off, with one switch in settings, and the
README says plainly what an enabled server exposes.

## Shape

A second executable target, `TypeMeItMCP`, producing `type-me-it-mcp` and
embedded at `Contents/Helpers/` in both app targets. It speaks MCP over stdio
(newline-delimited JSON-RPC on stdin and stdout, nothing else on stdout — logs
go to stderr). The agent is configured once:

```sh
claude mcp add type-me-it -- "/Applications/type me it.app/Contents/Helpers/type-me-it-mcp"
```

The path is stable across Sparkle updates, so the config survives them.

Read-only tools answer from the JSON files with no running app. Live tools
connect to a UNIX-domain socket at `Store.directory/mcp.sock`, which the app
listens on only while the setting is on; with no socket, those tools return "type
me it is not running" rather than failing the connection.

### Why not the other two shapes

*An HTTP server inside the app.* Streamable HTTP would avoid the helper binary
and the socket, but it means a listening TCP port on a machine where the app
holds every transcript, plus origin and token handling we would own. stdio needs
none of that: the OS decides who can run the binary.

*A helper that does everything itself, including recording.* It would need its
own Microphone and Accessibility grants, its own model load (697 MB, seconds),
and would fight the app over the microphone. The app is the only sensible owner
of a dictation.

### Protocol layer: hand-rolled first

The surface used is `initialize`, `tools/list`, `tools/call`, and the standard
errors. That is roughly 150 lines of `Codable` over a line reader, in one file,
unit-testable in `TypeMeItTests` with no new dependency in a bundle we notarise.
The official `modelcontextprotocol/swift-sdk` is the right answer the moment we
want resources, prompts, sampling or progress notifications — the decision to
revisit, not a door to close. Write the transport so the tool implementations
never see JSON-RPC and the swap stays local.

## Phases

**0 — Split the models out.** `HistoryEntry` and `LearnedWord` sit in
`Store.swift` next to a `@MainActor @Observable` class the helper must not link.
Move both to `TypeMeIt/HistoryEntry.swift`, and list that file, `Insights/`,
`Plural.swift` and the few pure helpers the tools need in the new target's
`sources` in `project.yml`. No behaviour change; the tests that exist keep
passing.

**1 — Read-only server.** The helper, the transport, a `StoreReader` that
decodes both files (and tolerates an entry written by a newer app), and four
tools:

- `history_search` — `query`, `app`, `since`, `until`, `starred`, `limit`;
  returns id, timestamp, app, and `displayText`.
- `history_get` — one id, with `transcript`, `postProcessed`, `typed`, `edited`
  and the timings.
- `stats` — `InsightsStats` for a period, plus the top apps and categories,
  computed by the same `Insights` code the settings window uses.
- `words` — the custom words and what the learning engine has learned.

Defaults matter here: `limit` caps at something small, and `history_search`
returns text, never the recording files.

**2 — Live tools.** A listener in the app (POSIX socket on a `DispatchSource`,
or `NWListener` over `NWEndpoint.unix` if it holds up — verify before
committing to it), socket mode 0600 inside the support directory, one
length-prefixed JSON request per connection, handled on the main actor:

- `dictate` — opens the microphone as the menu's Start Recording does
  (`Shortcuts.startFromMenu`), shows the usual pill so a recording is never
  invisible, stops on silence or `timeout`, and returns the text instead of
  pasting it. Needs a path through `Pipeline` that delivers to a caller rather
  than `Output.paste`.
- `clean_up` — `PostProcessor.run` on text the agent supplies, with the writing
  styles; the one tool that is useful even with an empty history.
- `add_custom_word`, `star` — small writes, through `Settings` and `Store` on
  the main actor, so the in-memory copy stays the truth.

Refuse `dictate` while a dictation is already running (`Shortcuts.Phase`), and
one connection at a time.

**3 — Settings and docs.** A row under the existing groups: the switch, and a
button that copies the `claude mcp add` line for this install (the dev build's
own path when it is the dev build). Copy stays short — the row is "MCP", not an
explanation of what MCP is; the caption says where the command goes. README
gains a paragraph on what an enabled server exposes.

## Tests

`TypeMeItTests` covers the framing (a split write, two messages in one read, an
unparseable line), the `initialize` handshake, a snapshot of `tools/list` so a
schema change is deliberate, and every filter in `history_search` against a
fixture directory pointed at by `TYPEMEIT_SUPPORT_DIR` — which exists already
for the screenshot runs. The live tools get one test each against a fake
listener, not the real app.

Manually: build the dev app, point `claude mcp add` at
`build/dd/Build/Products/Debug/type me it dev.app/Contents/Helpers/type-me-it-mcp`,
and check that the server with no app running still answers the read-only tools.

## Not in this

No HTTP or SSE transport, no access from another machine, no audio or recording
files over MCP, no tool that changes settings beyond the custom words, and no
history deletion — an agent that can erase the record is a bad trade for a
feature whose whole value is reading it.

## Open questions

- Does the App Store build ship the helper at all? It works (an unsandboxed
  agent can execute it and read the container), but it is worth asking whether
  review reads a helper binary in a sandboxed app the way we do.
- `dictate` needs a `Pipeline` path that returns text instead of pasting. Is
  that a parameter through the existing flow, or a second, thinner flow that
  shares the transcriber?
- Should an enabled server put something in the menu bar? An agent reading the
  history leaves no trace today.
