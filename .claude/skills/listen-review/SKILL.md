---
name: listen-review
description: Decide when a human must listen to check speech-to-text, and run that check with the least listening. Use when models or transcripts disagree and the scores can't settle who is right, when a trial's verdict hangs on disputed spans, when asked to review transcription output, or when told a dictation or meeting transcript was bad.
---

# Listen review

Scores against a reference only say who agrees with the reference. The user's
ear is the ground truth, and the scarcest resource in the eval: machines settle
everything they can first, and the ear gets only the spans that change the
meaning and that no machine can settle. Every answer is kept for good.

Commands are `make asr-eval ARGS="..."` (Scripts/asr-eval/README.md). Paid calls,
judgements and answers are all cached; never pay, judge or ask twice.

## 1. Machines first

Work down this funnel; each step shrinks what reaches the ear.

1. **Reference.** The reference is AssemblyAI Universal-3.5 Pro, prompted for a
   verbatim transcript. Unprompted it tidies (drops repeats and false starts),
   which charges the most literal model with errors it did not make. Build
   references only for the chosen clips: `build --keep`.
2. **Scripts.** Fillers, digits against words, punctuation and contractions are
   settled by code (`score --no-fillers`); never put them in front of the ear.
3. **Meaning judge.** Whether a disputed span changes the meaning is a text
   question. `judge-export --out <file>` writes the spans not yet judged; split
   them into batches of about 190 and run one Opus agent per batch, in parallel,
   with `Scripts/asr-eval/judge-prompt.md` ({in} and {out} filled in). Check every
   output line against its input, then `judge-import <file> --by opus-5.5`.
   `score --meaning` then reports WER on the spans that change the meaning.
   Opus cannot hear: "was it said" stays with the ear.

## 2. Decide whether to ask

State the question, and what each possible answer would change. Then work out
the swing: if every span in the set went the candidate's way, would the
decision flip? When it cannot flip (Fluid Speech Mini, 2026-10-17: its own extra
words were worth 0.5 points against a 1.4-point gap), the numbers decide;
log the verdict and do not ask.

## 3. Build the smallest set that answers it

About 40 spans, ten minutes of listening, drawn at random within groups so the
answers can be extrapolated. Spans a truth already settles are skipped.

- **Which reading was said:** `pick-set <name> --a <system> --b <system>` draws
  spans judged to change the meaning where the two disagree, evenly from three
  groups (the reference agrees with A, with B, or with neither). The page shows
  the readings blind, as A, B, C in shuffled order; keys 1–9 pick, 0 is none.
- **Were these extra words said:** an insertion set (`review --set
  ultra-insertions` builds one) asks about words one system adds alone:
  R said, M said but the meaning is the same either way, W someone spoke but
  not those words, H nothing was said.
- **Who said it:** `who-set <name> --a <diarizer> --b <diarizer>` draws
  stretches of words the two diarizers give to different people (outputs in
  the reference dir's `diarizers/`). Each plays a sample of each voice from
  the same track, blind as person A and person B, then the words; keys 1, 2,
  0 for neither. Its answers are not truths (they say who, not what):
  `truths-import` refuses them, and the counts go in `docs/model-trials.json`
  (then `make model-trials`).
  Speaker references are unprompted: run it with `ASSEMBLYAI_PROMPT=''`.

Serve it with `review --set <name> --html` (127.0.0.1 only). Before handing it
over, serve it on a copy of the reference dir (`ASR_EVAL_DIR`), answer one span
and confirm the real answers file is unchanged. Give the user one command and
the listening time. The clips and transcripts are private: never publish the
page or a snippet, and never paste transcript text in chat.

## 4. Keep the answers

Done means all three:

1. `truths-import <name> --by <listener>` turns the answers into truths: what was
   said in a clip between two times. Truths survive any change of reference or
   system set; every later `score` applies them and every new set skips them.
2. `vault-save`, with `ASR_EVAL_VAULT_KEY` read from 1Password ("type me it eval
   vault key", Personal), encrypts all truths and an audio snippet for each
   into `Scripts/asr-eval/vault/truths.tmv`; commit that file. `vault-load`
   restores them on another Mac.
3. The result is in `docs/model-trials.json` (`make model-trials` rebuilds the
   Markdown table and the web page): counts per answer, the corrected
   numbers, and whether the decision changed. For a bad-transcript report,
   say what caused it (model, clean-up, echo, diarization) and what to change.

## A bad transcript

When told a dictation or meeting transcript was bad, find it first: dictations
in history, meetings through the typemeit MCP (`list_meetings`,
`get_meeting`); the audio is in the app's data dir. Then run the funnel on that
recording alone.
