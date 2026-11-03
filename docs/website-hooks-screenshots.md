# Website copy and screenshots: claude in meetings

Spec for the meetings section's claude features: asking claude mid-meeting,
and the mcp block, which now takes in hooks. Agree the copy first, then build
and capture. Every name, company and number is made up and continues the
"Launch date and pricing" meeting already on the site (`web/shots/meeting.webp`):
the same invented Sam Rivera and Priya Shah.

## Page copy

The separate hooks block goes. The meetings column reads: record prompt,
summary, sharing, speakers, **ask claude**, **mcp**.

**ask claude** (new)

> say "claude, …?" in a call and type me it offers to ask. claude code answers
> from the call so far, with your mcp servers, and keeps the answer with the
> meeting.
>
> *[the pill, drawn in HTML like the record prompt: `claude, what did we charge
> the pilot customers last year?` · `no` · `ask claude`]*
>
> note: turn on on camera and the answer shows in your video too.

**mcp** (updated)

> ask claude, codex or any ai app about your meetings and dictations. add type
> me it to any app that supports mcp, and it can read and search them, and set
> up hooks: prompts claude code runs on a meeting once it ends.
>
> `list_meetings` `get_meeting` `search_meetings` `meeting_stats`
> `list_dictations` `search_dictations` `list_hooks` `add_hook` `update_hook`
> `remove_hook` `get_system_prompt` `update_system_prompt`
>
> note: ask and hooks send the transcript to anthropic.

## Pictures, in the pics column

1. **The answer pill** (HTML, no capture), after the existing meeting shot:
   the pill grown open with the answer.
   - question: `claude, what did we charge the pilot customers last year?`
   - answer: `19 once, for lifetime. It's in the "Pilot pricing" call from 12 March: Sam set it, Priya confirmed it with the store team.`
2. **`hooks-meeting.webp`** (capture), replacing `meeting.webp`: the same
   meeting page with, between the summary and the transcript, the hooks
   subhead and one run:
   - name `follow-up email` · `9 Oct 2026 at 10:41`
   - prompt line: `draft a follow-up email with what was decided and who does what`
   - answer:
     > Subject: Launch moves to the 15th
     >
     > Hi Sam, hi Priya, thanks for this morning. We agreed:
     > - The launch moves from the 8th to the 15th, so the pricing test runs first.
     > - Sam sends the revised numbers on Friday.
     > - Priya tells the store team today.
3. **The terminal** (HTML, exists): keeps its mcp question, and adds a hook:
   ```
   > after each meeting, draft a follow-up email

   add_hook   follow-up email · off

   Added "follow-up email". Switch it on in type me it settings, under ai assistant.
   ```

Alt text: "a meeting's page with a follow-up email a hook drafted above the
transcript".
