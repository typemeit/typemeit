# Calling an AI CLI from inside the app

Type Me It cleans transcripts with Apple's on-device model (`PostProcessor.swift`),
which is free, private and fast enough. A coding-agent CLI on the user's Mac —
`claude`, `codex`, `gemini` — is a different kind of backend: it reads files, runs
commands and works a task rather than rewriting a sentence. This note records
whether a third-party app may drive one at all, what each vendor's terms allow,
what it would cost, and the shape it would take here. Written September 2026.

Nothing below is a commitment to build it. It is what we would have to honour if
we did.

## Two layers, and they are independent

Every CLI here has a code licence and a backend service term, and reading only
the first is the usual mistake. Apache 2.0 on the repository says you may fork,
modify and redistribute the binary. It says nothing about whose credentials may
reach the vendor's servers. The restrictions that bite are almost always in the
second layer.

| CLI | Code licence | May we spawn the user's own install? | May we ship our own? |
|---|---|---|---|
| Claude Code | Proprietary | Yes — documented subprocess pattern | No |
| Codex | Open source (CLI repo Apache 2.0) | Yes — plus a supported embedding surface | Yes |
| Gemini CLI | Apache 2.0 | **No** — named as a violation | Yes, with API-key auth only |
| Copilot CLI | Proprietary | Unstated | No |
| Cursor CLI | Proprietary | Unstated | No |

### Claude Code

The Agent SDK docs point non-Python/TypeScript callers at exactly what we would
do: "To drive the same agent loop from another language, run the CLI as a
subprocess with the `-p` flag and `--output-format json`." [Agent SDK
overview][agent-sdk], [Headless mode][headless]

The restriction is on auth, not on invocation: "Unless previously approved,
Anthropic does not allow third party developers to offer claude.ai login or rate
limits for their products, including agents built on the Claude Agent SDK."
[Agent SDK overview][agent-sdk] The distinction is whose credentials flow
through whose infrastructure. A user who
ran `claude login` themselves, on their own Mac, consuming their own
subscription, is not us offering them anything. Extracting their OAuth token,
proxying it, pooling accounts or advertising "includes Claude usage" would be.

The consumer terms reinforce it from the other side: no accessing the services
"through automated or non-human means" except via an API key or where explicitly
permitted, and no reselling. [Consumer terms][consumer-terms] Use of the SDK
and CLI is governed by the [Commercial terms][commercial-terms], including when
they power products made available to our own users.

### Codex

The most permissive of the three, and the only vendor that has shipped a surface
built for this. Three layers, all published open source: `codex exec` for
non-interactive runs returning structured output, a programmatic SDK, and
`codex serve`, an app-server for "when the agent is part of the product itself.
It lets your application connect to a local Codex process, keep conversations
open, stream events, interrupt work, expose tools, and respond to approval
requests." [Codex as a platform][codex-platform], [SDK][codex-sdk],
[Non-interactive mode][codex-noninteractive] That is our use case described by
the vendor.

### Gemini CLI

Apache 2.0 and fully forkable, but the one that explicitly closes the door we
want to walk through: "Directly accessing the services powering Gemini CLI (for
example, the Gemini Code Assist service) using third-party software, tools, or
services (for example, using OpenClaw with Gemini CLI OAuth) is a violation of
applicable terms and policies." [Gemini CLI terms][gemini-tos]

So Gemini is API-key-only for us. The subscription path is out, whatever the
licence says about the code.

### Copilot CLI and Cursor CLI

Closed source, subscription-authenticated, nothing published either way. Treat
them like Claude Code: drive a user's existing install, never redistribute,
never broker the login. Revisit if either publishes an embedding position.

## Branding

Anthropic's are the only published constraints, and they are specific. Allowed:
"Claude Agent", "Claude" inside a menu already labelled Agents, or
"Type Me It Powered by Claude". Not permitted: "Claude Code", "Claude Code
Agent", Claude Code-branded ASCII art, or visual elements that mimic Claude Code.
The product must keep its own branding and not appear to be an Anthropic
product. [Agent SDK overview][agent-sdk]

A settings row naming the tool the user picked is fine. A row that reads
"Claude Code" as a feature name is not.

## Distribution

The Mac App Store sandbox effectively rules out spawning arbitrary user-installed
binaries, so this feature and that distribution channel are mutually exclusive.
Type Me It ships with a Developer ID signature, so it is not a blocker today —
but it closes the App Store door if we ever wanted it, and that tradeoff should
be made deliberately rather than discovered later.

## Why not bring-your-own-key

The obvious alternative is to skip the CLI, take an API key from the user and
call the model directly. For rewriting a transcript that is genuinely cheap.
Current first-party rates are $1/$5 per million input/output tokens for
Haiku 4.5 and $2/$10 for Sonnet 5. [Pricing][pricing] A 300-word transcript
with our ~400-token instruction block is roughly 800 tokens in and 400 out:

| Volume | Haiku 4.5 | Sonnet 5 |
|---|---|---|
| One dictation | $0.003 | $0.006 |
| 20 a day | $1.70/month | $3.40/month |
| 50 a day | $4.20/month | $8.40/month |

But that is the argument for *not using a CLI at all*. If the job is a rewrite,
call the API and skip the subprocess, the version detection and the whole terms
question — and note that Apple Intelligence already does this job for nothing.

The reason to want a CLI is agentic work: long context, many turns, tool loops,
whole files read into the prompt. There metered billing loses badly to a flat
subscription, and the user is already paying for one. Asking them for an API key
on top is asking them to pay twice for something they have. That is what decides
the design below.

## The shape it would take

1. **Off by default, behind a setting.** A dictation app that shells out to an AI
   agent without being asked is not what anyone installed. `Settings` gets a
   `Bool` in the existing `didSet`/`UserDefaults` style, defaulting to `false`,
   and every code path below is dead until it is on.
2. **Detect, never bundle.** Look for binaries the user already has. If none is
   found, the setting stays off and says so; we do not offer to install anything.
3. **Never hold credentials.** No token reading, no `~/.claude` or `~/.codex`
   parsing, no proxying, no key entry field for a subscription-backed tool. The
   child process authenticates itself or fails. This is the invariant that keeps
   every vendor's terms satisfied at once.
4. **The user picks the tool.** A second setting for which detected CLI to use,
   and the path, so a non-standard install works.
5. **Gemini is the exception.** If it is ever supported, it needs its own API-key
   path, not the spawn path. Do not let it fall through the generic detect
   branch.
6. **Spawn non-interactively.** `claude -p … --output-format json`, `codex exec`,
   parse structured output, timeout, surface failures as a normal app error.

## Recommendation

Detect-and-spawn, behind a setting that is off until the user turns it on, using
the CLI they already installed and already logged into. It is the only design
that does not charge the user twice, and the credential invariant in point 3 is
what keeps it inside every vendor's terms rather than relying on a reading of
them.

Bring-your-own-key stays the fallback for small rewrite work, where it is worth
a third of a cent a dictation — but that work has a free on-device answer
already, so the fallback may never be needed.

Codex is the one to build against first: it is the only vendor with a supported
embedding surface, so the integration is least likely to break on a terms change.
Claude Code second, on the documented subprocess pattern. Gemini last and only
with API keys. Copilot and Cursor not until they publish a position.

One caveat worth keeping: the boundary between "the app drives the user's own
CLI" and "the app offers a vendor's subscription to its users" is not spelled out
beyond the quotes above. Before shipping this commercially, put the design to
Anthropic and OpenAI directly rather than relying on our reading. This note is
research, not legal advice.

[agent-sdk]: https://code.claude.com/docs/en/agent-sdk/overview
[headless]: https://code.claude.com/docs/en/headless
[consumer-terms]: https://www.anthropic.com/legal/consumer-terms
[commercial-terms]: https://www.anthropic.com/legal/commercial-terms
[codex-platform]: https://developers.openai.com/blog/codex-as-a-platform
[codex-sdk]: https://developers.openai.com/codex/sdk
[codex-noninteractive]: https://developers.openai.com/codex/noninteractive
[gemini-tos]: https://github.com/google-gemini/gemini-cli/blob/main/docs/resources/tos-privacy.md
[pricing]: https://claude.com/pricing
