# Kyutai STT

Research agent report, 2026-09-25 (web sources as cited; claims marked unverified are as the agent flagged them).

5.
- 2026 status: org active (Hibiki-Zero speech-to-speech Feb 2026, "post-training speech models for better interactivity" Jun 10 2026), but no confirmed new stt-1b/stt-2.6b version release found in 2026 — UNVERIFIED whether STT models themselves were updated this year. kyutai.org/blog/2026-06-10-interactivity/
- WER (open-asr-leaderboard): stt-2.6b-en gets LibriSpeech-clean 1.70%, LibriSpeech-other 4.32%, AMI 12.17%, mean 6.4. huggingface.co/kyutai/stt-2.6b-en
- Streaming: natively streaming, decoder-only "Delayed Streams Modeling"; algorithmic delay 0.5s (stt-1b-en_fr) or 2.5s (stt-2.6b-en); underlying Mimi codec itself has 80ms latency at 12.5Hz/1.1kbps. kyutai.org/stt/ github.com/kyutai-labs/moshi
- On-device: yes — MLX build targets Mac/iPhone local inference; Rust/candle build also runs locally; PyTorch is for research; Rust server is the GPU/cloud production path (H100: 400 concurrent streams). github.com/kyutai-labs/delayed-streams-modeling
- License: code is MIT (Python) + Apache-2.0 (Rust); model weights are CC-BY 4.0. github.com/kyutai-labs/delayed-streams-modeling
