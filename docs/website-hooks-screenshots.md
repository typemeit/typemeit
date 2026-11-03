# Website screenshots: hooks

Copy spec for the screenshots the website's hooks block needs. Agree this
first, then seed and capture. Every name, company and number here is made up;
it continues the "Launch date and pricing" meeting already on the site
(`web/shots/meeting.webp`), so the people are the same invented Sam Rivera and
Priya Shah.

Both captures: the dev app's settings window, dark, 2000 px wide like the
existing shots (2x, landscape, `.webp`), saved to `web/shots/`.

## 1. `hooks-meeting.webp`: a meeting after run hooks

The meeting page of "Launch date and pricing", scrolled to the top. Between
the summary and the transcript, the **hooks** subhead and two runs, oldest
first. The run hooks button is gone (both hooks have run), which is right.

**Run 1**

- name: `follow-up email`
- when: `9 Oct 2026 at 10:41`
- prompt line: `draft a follow-up email to everyone who spoke, with what was decided and who does what`
- answer:

  > Subject: Launch moves to the 15th
  >
  > Hi Sam, hi Priya,
  >
  > Thanks for this morning. What we agreed:
  >
  > - The launch moves from the 8th to the 15th, so the pricing test runs first.
  > - Half the visitors see 2.99 a month, half see 19 once, for a week.
  > - Sam sends the revised numbers on Friday.
  > - Priya tells the store team today.
  >
  > Shout if I missed anything.

- footer: none (a kept run shows no time or model)

**Run 2**

- name: `action items`
- when: `9 Oct 2026 at 10:42`
- prompt line: `file each action item as an issue in linear, assigned to whoever took it`
- tool calls:
  - `linear · create_issue` → `LAU-212 Send revised pricing numbers`
  - `linear · create_issue` → `LAU-213 Tell the store team the launch moved`
- answer:

  > Filed 2 issues in Launch:
  >
  > - LAU-212 Send revised pricing numbers · Sam Rivera · due Fri 10 Oct
  > - LAU-213 Tell the store team the launch moved · Priya Shah · due today

The right column (people, where, folder, processing) stays as it is in the
existing meeting shot.

## 2. `hooks-settings.webp`: the hooks rows in settings

Settings, the **ai assistant** page, scrolled so the hooks rows fill the
window: the "everywhere" subhead and its blurb at the top, ask on, then:

| row | switch | prompt (in the editor below the row) |
| --- | --- | --- |
| hooks | (field "name a new hook" · add) | |
| follow-up email | on | `draft a follow-up email to everyone who spoke, with what was decided and who does what` |
| action items | on | `file each action item as an issue in linear, assigned to whoever took it` |
| update the crm | off | `if a customer was on the call, add a note to their company in the crm with what they asked for` |

"update the crm" is off because an assistant added it over mcp, which is what
the note under the hooks block on the site says.

## 3. The terminal beside the screenshot (HTML, not a capture)

Under the screenshot in the meetings column, like the existing Claude Code
block, showing an assistant adding a hook over mcp:

```
> every time a meeting ends, draft a follow-up email

add_hook   follow-up email · off

Added "follow-up email". Switch it on in type me it settings, under ai assistant, hooks.
```

## Website copy that goes with them

The hooks block as it stands on the page, for the record:

> **hooks**
> save prompts like "write the follow-up email" or "file the action items".
> when a meeting ends, press run hooks and claude code runs each one on the
> transcript, with your mcp servers. what it writes shows on the meeting's page.
>
> needs claude code, which sends the transcript to anthropic. hooks an
> assistant adds over mcp start off.

Alt text:

- `hooks-meeting.webp`: "a meeting's page with two hooks run: a follow-up email and action items filed in linear"
- `hooks-settings.webp`: "the hooks rows in settings: follow-up email and action items on, update the crm off"

## Open questions

- Linear by name, or a generic "issue tracker"? Naming it shows the mcp
  servers doing real work; the tool call names would read
  `linear · create_issue` either way only if the user has that server.
- Does the hooks block get its own screenshot in the pics column (it would
  sit after the meeting shot and the terminal), or replace the meeting shot
  with `hooks-meeting.webp`, which shows the same meeting plus hooks?
