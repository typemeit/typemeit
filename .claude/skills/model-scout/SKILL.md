---
name: model-scout
description: Daily scan for new models and runtimes from the last 7 days that could replace one typemeit ships, filtered and ranked into a short list worth trying; also logs trials. Use when asked to scout models, check for new ASR/diarization/LLM alternatives, or record the result of a model trial.
---

# Model scout

Two jobs. **Scout** runs daily on the user's Mac (a local scheduled task), not in the cloud: the cloud sandbox blocks Hugging Face, arXiv, Reddit and the GitHub feeds. **Log** runs
whenever a model is tried locally.

## PRs

Every PR this skill opens (a report, a no-picks update, a trial, a change to
this skill) is merged as soon as it is open: `gh pr merge --squash`, never
`--admin`, with no wait for review. No AI attribution in any commit, branch or PR.

## Models we ship

Keep this list current: CLAUDE.md requires any change that adds or swaps a
model to update it.

| Role | Model | Configured at | Eval that proves "better" |
|---|---|---|---|
| Speech recognition | FluidAudio Parakeet Ultra (Core ML, Neural Engine), HF revision `95eaa59a`, via FluidAudio 0.17.6 | `TypeMeIt/ModelStore.swift`, `Scripts/asr-model.sh`, `project.yml` | `make asr-eval` (Scripts/asr-eval): WER against an AssemblyAI reference with disagreements hand-checked; add the candidate as one file in `systems/` |
| Clean-up | Apple Foundation Models, permissive guardrails | `TypeMeIt/PostProcessor.swift` | `make eval` (Scripts/cleanup-eval) |
| Meeting summaries and titles | Apple Foundation Models | `TypeMeIt/Meetings/MeetingSummary.swift` | `make meeting-eval` |
| Opening "Can" check | Apple Foundation Models | `TypeMeIt/OpeningCan.swift` | `make eval` cases |
| Diarization | Nemotron 3 Diarization, CoreML offline, weights `ga-2026-09-23` | `TypeMeIt/Meetings/Diarizer.swift`, `DiarizerModelStore.swift` | `make asr-eval ARGS=score`: wrong-speaker word rate vs AssemblyAI labels. The Nemotron baseline adapter is still a stub |
| Ask Claude: finding the question | Claude Haiku via Claude Code (`--model haiku`, no tools or MCP) | `TypeMeIt/Meetings/ClaudeRun.swift` `latestQuestion` | None |
| Speaker segmentation and embeddings | pyannote community-1 + WeSpeaker 256-d + VBx, via FluidAudio 0.17.6 | `project.yml`, `Diarizer.swift` | None. `docs/voice-names-research/` scripts are ad hoc |

The evals use one paid model, tracked the same way:

| Role | Model | Configured at | Eval that proves "better" |
|---|---|---|---|
| Eval reference (paid, cloud) | AssemblyAI Universal-3.5 Pro (`universal-3-5-pro`) since 2026-10-17; Universal-2 before | `Scripts/asr-eval/assemblyai.py`, `ASSEMBLYAI_SPEECH_MODEL` | Run the candidate on the 12 meeting tracks and 50 dictations, then the user judges the spans where it and the current reference disagree (`listen-review` skill) |

Runtimes to watch: FluidAudio, mlx-swift-lm / mlx-lm,
llama.cpp, transcribe.cpp, sherpa-onnx, mlx-audio, Apple Foundation Models.

## Scout

1. Read `docs/model-trials.md`, `docs/model-scout/seen.json`, and the report
   and `seen.json` on every open `model-scout-*` PR (`gh pr list --state open
   --search "Model scout"`). Skip any model already in one of them.
2. Check FluidAudio releases newer than the pinned version in `project.yml` for new ASR or diarizer models.
3. Fetch items from the last 7 days with curl; drop anything whose HF
   `createdAt` (or feed date) is older. An empty result for an org is normal.
   Three exceptions to the 7-day window:
   - Libraries the app pins (FluidAudio in `project.yml`): read every release newer than
     the pinned version, however old, and read each release's notes in full.
     Model variants often appear only in a comparison table there (Phonon-2
     and Ultra were in FluidAudio 0.17.5's notes and the 7-day window missed both).
   - Available but untried: list every model the pinned version of each
     library can load (for FluidAudio, the cases of `AsrModelVersion`, the
     diarizer, VAD and speaker-embedding models in `ModelNames.swift`). Any one not in
     `docs/model-trials.md` is a candidate, whatever its age. Ultra shipped
     in FluidAudio 0.17.3, older than our pin, and went untried for three weeks.
   - A model in `seen.json` comes back if it has gained a benchmark or an
     Apple Silicon build since it was seen.
   - Hugging Face API (`https://huggingface.co/api/models?author=<org>&sort=createdAt&limit=30`):
     FluidInference, mlx-community (≤4B params), nvidia (search parakeet,
     sortformer, titanet, canary), pyannote, argmaxinc, onnx-community,
     handy-computer (transcribe.cpp's GGUFs).
     Also `pipeline_tag=text-generation&sort=trendingScore` and
     `filter=gguf&sort=createdAt`.
   - GitHub `releases.atom`: FluidInference/FluidAudio, argmaxinc/WhisperKit,
     argmaxinc/OpenBench, ml-explore/mlx-swift-lm, ml-explore/mlx-lm,
     ggml-org/llama.cpp (only titles adding a model architecture), k2-fsa/sherpa-onnx,
     Blaizzy/mlx-audio, pyannote/pyannote-audio, NVIDIA-NeMo/NeMo,
     handy-computer/transcribe.cpp.
   - Open ASR Leaderboard rows: `python3 .claude/skills/model-scout/leaderboard.py`
     prints the short-form table as CSV, proprietary rows and `License`
     included, from the leaderboard Space's API; the results datasets behind
     it went private on 2026-10-22. Rows have no date, but the leaderboard is
     versioned: `--versions` lists the version ids, and a row is new if it is
     missing from `--version <the last id before the previous scout>` and its
     model id is in neither `seen.json` nor `model-trials.md`. Compare
     `Average WER` and `AMI-Cleaned`. A row with an empty column averages
     fewer sets, so compare it on the shared columns.
   - arXiv: `https://export.arxiv.org/api/query?search_query=cat:eess.AS+AND+(all:diarization+OR+all:%22speaker+embedding%22+OR+all:transducer+OR+all:%22streaming+ASR%22)&sortBy=submittedDate&max_results=50`.
     Read an abstract only when it mentions released weights. When the API
     rate-limits (in the browser too), scan titles on
     `https://arxiv.org/list/eess.AS/pastweek?show=2000` instead.
   - HF Daily Papers `https://huggingface.co/api/daily_papers?limit=50`;
     keep titles naming speech, ASR, diarization or speaker.
   - Hacker News `https://hn.algolia.com/api/v1/search_by_date?tags=story&query=<q>`
     for parakeet, whisper, diarization, on-device LLM; keep stories over 20 points whose title names a model or runtime.
   - Reddit `https://www.reddit.com/r/LocalLLaMA/top/.rss?t=week` and
     `/r/speechtech/.rss`, with a custom User-Agent and a few seconds between
   them. A 429 or other failure is skipped and listed under Source status.
     Run from a Mac, r/speechtech is read in the user's Chrome with the
     Control Chrome tools (`open_url`, `execute_javascript`, `get_page_content`):
     the Claude in Chrome extension and the built-in browser both refuse
     reddit.com. Open `https://www.reddit.com/r/speechtech/`, then run a script
     that fetches `/r/speechtech/new.json?limit=100&raw_json=1` (follow `after`
     back to the last scout date, or four months on a first run). The tool does
     not return a script's value, so write the result into the page
     (`document.body.innerHTML = "<pre id=o></pre>"`) and read it with
     `get_page_content`; a long fetch loop is started in one call and read in a
     later one. Scan every title; for each speech recognition, diarization,
     echo or clean-up release, read the body and top comments.
   - Leaderboard and card checks: a leaderboard row has no size or licence
     beyond its columns, so open the Hugging Face card before trusting it, and
     check its training data for the eval's corpora (step 5).
   - Paid speech APIs, for the eval reference role. No 7-day window: a
     change in the ranking is the finding.
     - Open ASR Leaderboard rows with `License` "Proprietary" (`leaderboard.py`),
       and `leaderboard.py --private` for the private scripted and
       conversational averages. Diff against the previous version for a
       ranking change. The per-vendor provenance files went private with the
       datasets, so whether a number was contributor-reported now shows only in
       the leaderboard's changelog and the vendor's PR to
       `huggingface/open_asr_leaderboard`; one the maintainers ran ranks above it.
     - Long-form: `leaderboard.py --longform`.
     - Artificial Analysis `https://artificialanalysis.ai/speech-to-text/non-streaming`
       (independent; no AMI, no diarization) and Voice Arena
       `https://voicearena.com/stt-leaderboard/us-english` (independent,
       phone calls; needs the browser).
     - Vendor feeds: `https://developers.zoom.us/changelog/rss.xml`,
       `https://elevenlabs.io/docs/changelog.rss`,
       `https://www.assemblyai.com/llms/models.md`,
       `https://developers.deepgram.com/changelog.rss`,
       `https://developers.openai.com/api/docs/changelog.md`, and the Azure
       speech release notes
       `https://learn.microsoft.com/en-us/azure/ai-services/speech-service/releasenotes`.
   - When curl fails on any source (Hacker News and arXiv often do), retry
     it in a browser before giving up: chrome-devtools MCP (`new_page`, then
     `evaluate_script` to parse the JSON or XML; arXiv's Atom shows as text,
     so run it through `DOMParser`). Reddit is read through Control Chrome
     (above). List only sources that fail in the browser too.
4. Drop anything that fails a filter:
   - runs on-device on Apple Silicon (Core ML, MLX, GGUF, ONNX); cloud only
     for meetings and the eval reference. An eval reference candidate instead
     needs a self-serve API that takes a 1-hour file in one request and
     returns speaker labels and word timestamps; licence, size and budgets do
     not apply to it. Rank it by maintainer-run or independent numbers:
     AMI-Cleaned and the leaderboard's private conversational set for
     meetings, short conversational sets for dictation
   - English
   - licence allows shipping in a commercial app (CC-BY is fine, NC is out; CC-BY-SA is a flag, because mirroring the weights as our own Core ML build carries the same licence, so name it in the report and read `LICENSE-WEIGHTS` before a trial)
   - fits in 24 GB beside the app
   - publishes a number against what we ship or its nearest public proxy:
     WER vs parakeet-tdt-0.6b-v2 on the Open ASR Leaderboard, DER vs
     Nemotron or pyannote, EER for embeddings, or a dictation clean-up /
     text-normalisation score. Classifiers without one are dropped.
   - not a variant of a rejected model in `model-trials.md` with the same architecture
5. Rank what is left by expected gain on the role's metric. At most five picks.
   - Discount a benchmark the model trained on: a leaderboard AMI gain from a
     model with AMI in its training data is not a held-out number. Granite
     Speech 4.1 2B NAR claimed AMI 6.96 against 9.09 and lost on our meetings
     (2026-10-16).
   - A pick over a budget in "Judging a candidate" at every published size
     ranks below every pick that fits, and its heading names the budget.
6. If there are no picks and no FluidAudio findings, write no report. Still
   append the near misses to `seen.json` (step 8), commit on
   `model-scout-YYYY-MM-DD` with the title "Model scout YYYY-MM-DD: no picks",
   and open and merge the PR (see PRs). With no near misses either, stop.
7. Otherwise write `docs/model-scout/YYYY-MM-DD.md`. Give each pick a heading
   and these lines:
   - role, and the model it would replace
   - what it is, for a reader who has never heard of it: who made it, when it
     came out, and how it works in one or two plain sentences
   - the claimed numbers, with a link, and whether the benchmark's data is in
     its training set
   - licence and size (for an eval reference: price per hour and the API's model id)
   - provenance: who published it (person, lab or company, and their
     affiliation if stated), when it was created and last updated, where the
     code lives, what architecture or base model it builds on, downloads and likes
   - who uses it: open-source projects that reference it (`gh search code
     "<model name>"`, plus community ports on HF), with their star counts
   - the eval to run (from the table above) and the runtime that loads it, or
     "no eval exists" plus what to build. transcribe.cpp loads most open ASR
     families; `Scripts/asr-eval/systems/granite_nar.py` is the adapter to copy

   End with a **Near misses** list (one line each, the filter that failed)
   and a **Source status** list of any fetch that failed.
8. Append every pick and near miss to `seen.json` as
   `{"id": "<hf id or name>", "date": "YYYY-MM-DD", "role": "<role>"}`.
9. Commit on a branch `model-scout-YYYY-MM-DD`, then open and merge the PR
   (see PRs). The title is "Model scout YYYY-MM-DD". The body is the top pick
   in one sentence.

## Changing how the scout searches

A change to this skill's sources or search steps goes on its own branch and
PR (see PRs).

## Running a trial

- A community fine-tune of Parakeet TDT v3 that ships Core ML packages (Orukeet
  is the first) runs through `Scripts/asr-eval/fluidasr`'s `orukeet` mode:
  extract the bundle, set `ORUKEET_DIR`, `make asr-eval ARGS="run fluid-orukeet"`.
  Copy `systems/fluid_orukeet.py` for the next one. FluidAudio's
  `AsrModels.loadLocal` loads any bundle in the v3 layout.
- Downloading the weights needs the user's yes in chat, with filename, source
  and size, even when they asked for the trial. Check the SHA-256 against the
  model's manifest and extract under `build/`.
- `clips.json` holds more clips (100 dictations, 127 tracks) than the shipped baseline was run
  on (50 and 12): run a candidate with `--like fluid-ultra` so both score on the same set.
  Until the verbatim-prompted references are built, score with `ASSEMBLYAI_PROMPT=''`, which
  reads the unprompted Universal-3.5 Pro references.
- Score with `make asr-eval ARGS=score`. A score with `0 spans hand-checked`
  keeps AssemblyAI's reading for every disputed word, so it is not comparable
  with the shipped scores above; run `disagree` and `review` first, or compare
  only against systems scored the same way.

## Judging a candidate

Order: accuracy > speed > memory/CPU > file size. Memory/CPU means the model's memory and CPU/GPU use while it runs; power use
does not count. A lower axis only counts
once every higher one is within its budget, so the order is applied as
budgets plus a tie-break, not as a weighted score.

**Budgets** (a candidate over any budget is rejected, whatever else it wins):

| Axis | Dictation (live) | Meetings (after the call) | Clean-up and summaries |
|---|---|---|---|
| Accuracy | WER ≤ shipped + 0.2 points | WER ≤ shipped + 0.2 points | no new `make eval` failures |
| Speed | p95 ≤ 300 ms per dictation | ≥ 5× realtime (1 h call done in 12 min) | p95 ≤ 500 ms; summaries ≥ 5× realtime |
| Memory | ≤ 1.5 GB resident | ≤ 6 GB peak | ≤ 1.5 GB resident |
| CPU and GPU use | report average and peak | report average and peak | report average and peak |
| File size | ≤ 1.5 GB, and it must replace a model, not sit beside one: one speech model serves dictation and meetings | same | same |

Shipped scores, so a trial never re-runs the baseline. Update them in the
same change that ships a new model. The scores below are against the
Universal-2 reference; re-measure them once the Universal-3.5 Pro references
are built:

| Role | Model | Score | Measured |
|---|---|---|---|
| Speech recognition, meetings | Parakeet Ultra, app path (`run shipped`) | 14.71% WER unreviewed, 12.55% after the listen review (Parakeet GGUF was 12.57%), 12 tracks | 2026-10-12 |
| Speech recognition, dictation | Parakeet Ultra, app path (`run shipped`) | 4.09% WER, 50 clips (685 words), p50/p95 47/97 ms, ~310 MB, Neural Engine (GPU idle) | 2026-10-12 |

**Accuracy decides.** A candidate less accurate than shipped is rejected,
whatever it saves. Lower axes only break ties: when WER is within 0.2 points
of shipped (about measurement noise), the better of speed, then memory/CPU,
then file size wins.

Read substitutions, deletions and insertions beside WER, and each track's
word count against the reference's. Ultra's extra words are mostly real
speech AssemblyAI missed (listen review, 2026-10-12), so the review lowers
Ultra's WER; a candidate that drops words gains nothing from it and is
further behind than its unreviewed WER shows.

CPU and GPU use: sample once a second while the model transcribes. CPU is
the % of the model's own process (`ps`; with `/usr/bin/time -l`, its child), GPU is device utilisation (`ioreg -r -c
IOAccelerator`, "Device Utilization %"). Neural Engine work shows in neither,
so say which unit the model ran on. No budget yet: record the numbers so the
first trials set one.

Compare speeds as ratios, never as millisecond differences: 290 → 111 ms is
2.6× faster, not "180 ms saved". Two significant figures.

Speed counts by where it is felt: dictation latency is what the user waits
on after releasing the key, so it is measured per dictation (p50 and p95).
Meeting speed only has to stay inside budget; beating it earns nothing.

## Before a trial: explain the model, state the hypothesis

First tell the user what the model is: who made it, when it came out, how it
works, its claimed numbers and its known limits.

Run on a quiet Mac: no dev app, call or other eval using the GPU (`pgrep`,
and `ioreg` utilisation before starting). If something was running, say so in
the row.

Before running anything, write down in the chat and in the log row:
- what the candidate should beat, on which metric, and by roughly how much
- why: the mechanism, and how the app already handles the same problem
  (read the shipped code path first; a release note's claim may not apply)
- what result would prove it wrong
- a prediction for every axis in "Judging a candidate": accuracy, speed,
  memory/CPU, file size. A candidate expected to tie on accuracy is tested
  for the axis it should win on, and that is named.

Do not run a trial whose hypothesis predicts it loses on accuracy by more than
the 0.2-point tie: under these rules it cannot win. Log it as "not run" with
the reason.

Choose the eval from the hypothesis, so it measures the case the candidate is
supposed to win on.

## Log a trial

When a model has been tried, add one entry to `docs/model-trials.json`, the
only copy anyone edits: date, role, model (with its maker, release month and
how it works in one clause), against, hypothesis, metric, result, held,
verdict (shipped / rejected / open), link to the PR or rig. Numbers come from a
run, not a model card. If the role has no eval, build it in `Scripts/` first
and link it.

The same entry carries the fields typeme.it/models leads with, which are
public: `name` (the model as a reader would search for it), `group` and
`status` (the values `Scripts/model-trials.py` lists), and `summary`, one line
with the decisive numbers and no paths, branches or people. Then run
`make model-trials`, which rewrites `docs/model-trials.md`, `web/models.html`
and the sitemap line; the web CI fails if they are stale. When a trial changes
what the app runs, update `inUse` too.

Commit the entry, the generated files and the rig on their own branch, then
open and merge the PR (see PRs).
