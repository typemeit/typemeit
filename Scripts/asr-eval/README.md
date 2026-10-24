# asr-eval

Scores speech models and diarizers against an AssemblyAI reference. Only the words where
systems disagree with it are hand-checked; every span you do not review keeps AssemblyAI's
reading, so a score is biased toward AssemblyAI by the share left unreviewed (`score` prints
that share).

Everything private lives outside the repo, in `~/Library/Application Support/TypeMeIt/asr-reference/`
(under `TYPEMEIT_SUPPORT_DIR` if set; `ASR_EVAL_DIR` overrides it): audio symlinks, AssemblyAI
responses, system outputs, `review.jsonl`, `decisions.jsonl`. Clip ids are hashes, never meeting titles.

```sh
export ASSEMBLYAI_API_KEY=...
make asr-eval ARGS="build"               # kept meeting tracks + up to 50 dictations; --dictations N, --limit N
make asr-eval ARGS="build --keep"        # references for the clips already in clips.json, e.g. after changing the reference model; uploads nothing new
make asr-eval ARGS="run shipped"         # the app's own speech path (Scripts/asr-app-path); --force reruns
make asr-eval ARGS="run bark-pro --like fluid-ultra"  # Underdog Bark 3.0 Pro through fluidasr bark-pro, only on the clips fluid-ultra has output for (clips.json holds more than every system ran); BARK_PRO_DIR=<extracted coreml/>, default build/bark-pro/coreml
make asr-eval ARGS="run bark-plus --like fluid-ultra"  # Bark 3.0 Plus through its own Python runner; BARK_PLUS_DIR=<extracted coreml/ane/>, default build/bark-plus/ane; first run builds build/asr-eval-venv-bark
make asr-eval ARGS="run fluid-orukeet"  # needs ORUKEET_DIR=<extracted orukeet-r3-coreml-greedy/>; compiles its packages on first run
make asr-eval ARGS="run cohere"          # Cohere Transcribe 2B, MLX int8; first run builds a venv and downloads ~2 GB
make asr-eval ARGS="run fluid-speech-mini"  # FluidVoice's Fluid Speech Mini, Core ML through fluidasr local; first run downloads 243 MB
make asr-eval ARGS="run granite-nar"     # Granite Speech 4.1 2B NAR, transcribe.cpp Q8_0 on Metal; first run builds transcribe.cpp and downloads 2.5 GB
make asr-eval ARGS="run nemotron"        # diarizer; needs a CLI, see below
make asr-eval ARGS="run nemotron_app"    # diarizer: the turns plus the app's per-speaker embeddings and short-speaker merge; FLUIDAUDIO_VERSION=x.y.z builds against another tag
make asr-eval ARGS="disagree"            # writes review.jsonl
make asr-eval ARGS="review"              # plays each span (ffmpeg + afplay); number, t=type, r=replay, s=skip, q=quit
make asr-eval ARGS="review --between fluid-ultra fluid-orukeet"  # only spans where those two differ, dictations first
make asr-eval ARGS="score"               # WER per system, dictation and meetings apart (meetings add S/D/I); wrong-speaker rate per diarizer
make asr-eval ARGS="score --no-fillers"  # same with um, uh, er, erm, ah, hmm, mm dropped from both sides (core.FILLERS)
make asr-eval ARGS="score --meaning"     # also count only errors in spans judged to change the meaning (judgements.jsonl)
make asr-eval ARGS="pick-set NAME --a fluid-ultra --b parakeet"  # judged spans that change the meaning where the two disagree; then review --set NAME --html picks the reading that was said, blind
ASSEMBLYAI_PROMPT='' make asr-eval ARGS="who-set NAME --a nemotron_app-0.17.5 --b nemotron_app-0.17.6"  # stretches two diarizers give to different people; review --set NAME --html plays a sample of each voice, then the words
make asr-eval ARGS="truths-import NAME --by max"   # a set's answers become truths (truths.jsonl), applied by every later score
make asr-eval ARGS="vault-save"   # truths + audio snippets, gzipped then AES-256-GCM, into vault/truths.tmv; ASR_EVAL_VAULT_KEY from 1Password ("type me it eval vault key")
make asr-eval ARGS="vault-load"   # restore them on another Mac
make asr-eval ARGS="judge-export --out spans.jsonl"  # disputed spans not yet judged; Claude Code agents label each, then:
make asr-eval ARGS="judge-import labels.jsonl --by opus-5.5"  # {judgeKey, matters, kind, note} per line, kinds in core.JUDGE_KINDS
make asr-eval ARGS="review --set ultra-insertions"  # 40 spans where fluid-ultra adds words neither AssemblyAI nor Parakeet has; r=real / m=said, doesn't matter / w=speech, wrong words / h=hallucination / s=skip / p=replay / q=quit
make asr-eval ARGS="review-summary"      # real vs hallucinated share and meeting WER if the real ones counted as correct
make asr-eval-test                       # unit tests, fixture text only
```

`build` posts each file once (`speech_models: ["universal-3-5-pro"]`, prompted for a verbatim transcript, audio tags removed, override with
`ASSEMBLYAI_SPEECH_MODEL`; `speaker_labels` on for the `others` and `room` tracks) and caches the
response by audio hash, so reruns never call again. Meeting tracks are scored separately: `mic`
is one speaker, so only `others` and `room` get the wrong-speaker rate. Scores before 2026-10-17
are against Universal-2; `ASSEMBLYAI_SPEECH_MODEL=universal` reads those references.

Comparison is on lower-cased words with punctuation dropped. "twenty five" against "25" counts
as a difference, and shows up in the review.

Decisions are keyed by clip, AssemblyAI word range and its words. Running a new system can widen a
span, and a widened span needs a new decision.

## Saved evals

Everything a run produces stays on this Mac, in the reference dir
(`~/Library/Application Support/TypeMeIt/asr-reference/`), and is never
committed: it holds meeting audio and transcripts.

| File | What it holds |
|---|---|
| `clips.json`, `aai/`, `audio/` | the clips and AssemblyAI's reference transcripts |
| `systems/<name>/` | each system's cached transcripts |
| `review.jsonl`, `decisions.jsonl` | disputed spans and hand decisions on them |
| `<set>.json`, `<set>-answers.jsonl` | listening-review sets and the answers given by ear |
| `timings/` | per-clip latency and memory |

`docs/model-trials.md` records the numbers each set produced and names the set,
so a result can be traced to its answers here.

## Adding a system

- ASR: `systems/<name>.py` with `NAME` and `transcribe(items) -> {id: text}` (`items` is `[{id, path}]`).
- Diarizer: `diarizers/<name>.py` with `NAME` and `diarize(path) -> [{startMs, endMs, speaker}]`.

`systems/shipped.py` runs `Scripts/asr-app-path/run.sh`, which builds the app's own `Transcriber`
and meeting chunk loop behind a command line, so its score is the app's. Cached `parakeet` outputs
in the reference dir are the transcribe.cpp model shipped before 2026-10; they stay scoreable.

`systems/cohere.py` runs mlx-community/cohere-transcribe-03-2026-mlx-8bit through mlx-speech, which
needs Python 3.13 (`/opt/homebrew/bin/python3.13`). The first run creates `build/asr-eval-venv` and
downloads the weights to `build/asr-eval-models` (both git-ignored); the model runs in a subprocess,
`systems/cohere_worker.py`. It loads whole files, so use it on dictations, not meeting tracks.

## Wrong-speaker rate

Each reference word takes the speaker whose segment covers its midpoint (the nearest segment if
none does). The diarizer's labels are matched to AssemblyAI's by the assignment that agrees on the
most words; labels beyond the reference's count match nothing. The rate is the share of words
that disagree, the metric in `Diarizer.swift` and docs/meetings.md 8.2.

## Diarizers

`diar/run.sh` builds one command line over FluidAudio, with the app's `SpeakerFrames.swift` and
`SpeakerMerge.swift` copied in and its constants read from `Settings.swift`. `nemotron` is
`Diarizer.turns`; `nemotron_app` adds what `Diarizer.run` and `MeetingTranscriber.speakers` do next on
a track with no window count: one WeSpeaker embedding per speaker from its longest 30 s, then
`SpeakerMerge.absorbingShort`. It builds against the FluidAudio tag `project.yml` pins, or
`FLUIDAUDIO_VERSION`, each in its own `build/asr-eval-diar-<version>`. Outputs are cached by
diarizer name: rename the reference dir's `diarizers/nemotron_app` (e.g. to `nemotron_app-0.17.5`) to keep one version's run beside the next.
