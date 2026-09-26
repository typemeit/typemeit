# Whisper prompt biasing, latency and ITN

Research agent report, 2026-09-25 (web sources as cited; claims marked unverified are as the agent flagged them).

1.
- OpenAI's cookbook: prompting is "not especially reliable"; won't override audio; capped at 224 tokens, biases only first ~30s. https://developers.openai.com/cookbook/examples/whisper_prompting_guide
- whisper.cpp has no hotword/vocabulary-constraint decoding (unlike Coqui+KenLM); such a request was closed "not planned." https://github.com/ggml-org/whisper.cpp/issues/1979
- Measured: naive topic-only prompt worsened WER (0.217→0.238); best engineered prompt cut WER just 17% (→0.180), no guaranteed word inclusion — weaker than true hotword biasing. https://arxiv.org/html/2602.18966v1

2.
- whisper.cpp's linked benchmark thread predates turbo (opened 2022, turbo shipped Oct 2024) — no Apple Silicon turbo numbers exist there. https://github.com/ggml-org/whisper.cpp/issues/89
- WhisperKit (CoreML/ANE, not whisper.cpp/Metal): M2 Ultra runs turbo at 42x realtime default, 72x with GPU+ANE. https://github.com/argmaxinc/WhisperKit/discussions/243
- whispernotes.app (own CoreML app): M2 does 10min audio in 63s (≈9.5x realtime); iPad Pro M2 in 71s (≈8.5x). https://whispernotes.app/blog/introducing-whisper-large-v3-turbo
- No verifiable M1- or M3-specific whisper.cpp/Metal turbo figure found — UNVERIFIED.

3.
- Whisper paper: training "removes the need for a separate inverse text normalization step in order to produce naturalistic transcriptions" — raw output already looks ITN'd. https://arxiv.org/abs/2212.04356
- Confirmed by users: default output is numeral form ("13," "12th"), not spelled-out; a num2words post-process is needed to go back to words. https://github.com/openai/whisper/discussions/971
