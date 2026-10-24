# Local LLMs in place of the Apple model

Variant GL (`Scripts/postprocess-lab/variants/GL.patch`) is G with the conservative
gate, but the model call goes to `llama-server` on localhost instead of
`LanguageModelSession`: same instructions as the system message, same prompt as the
user message, greedy (temperature 0), the same response-token cap, thinking turned
off in the chat template. Everything else (gate, code passes, guards) is unchanged,
so differences come from the model alone.

Server: llama.cpp build 10809, Metal, all layers on the GPU, 8192-token context,
`--parallel 1 --cache-reuse 256` (with more than one slot, requests landed on a
cold slot and the instructions were prefilled again every call). Q4 GGUFs. One run
at a time, cold eval mode, M4 24 GB with other apps running. Harness:
`Scripts/postprocess-lab/llm/eval-model.sh`.

| model | eval | words only | wishes (words) | p50 ms | p90 | p95 | mean | decode ms/token | prompt tokens prefilled per call |
|---|---|---|---|---|---|---|---|---|---|
| Apple on-device model (G, conservative gate) | 335 | 335 | 6/14 | 718 | 1672 | 2084 | 863 | ~14 | all of it (cold mode, new session per call) |
| LFM2.5-1.2B-Instruct Q4_K_M | 271 | 273 | 4/14 | 677 | 1675 | 2270 | 770 | 13.9 | 409 (median) |
| Qwen3-4B-Instruct-2507 Q4_K_M | 240 | 242 | 6/14 | 629 | 3434 | 3855 | 1000 | 30.1 | 21 (median) |
| LFM2.5-8B-A1B Q4_K_M | invalid | — | — | 2128 | 5331 | 6408 | 2557 | 20.2 | 410 (median) |
| Gemma 4 E4B-it Q4_0 (6-call probe) | — | — | — | — | — | — | 574–982 per call | 34.6 | 26 (median) |

Per-case outputs: `eval/local-llm-*.json`.

## What went wrong, per model

- **LFM2.5-1.2B** decodes as fast as the Apple model, but its hybrid architecture
  (convolution + attention layers) gets no prompt-prefix reuse in llama.cpp, so each
  call prefills the ~410-token instructions again (~460 ms). Of its 64 failures:
  24 contractions the prompt did not ask for, 11 list/line-break shapes, 29 other
  word changes (cut the opening "um so I think", left "were meeting at there house"
  as heard, turned "notify" into "the notification", dropped "about the … release").
- **Qwen3-4B-2507** reuses the cached prefix (21 new tokens per call) but decodes at
  half the Apple model's speed. Of its 95 failures: 42 contractions not asked for,
  36 numbers written as digits without the digits style ("half past nine" →
  "9:30"), 15 other word changes. It fixed more mishearings than the Apple model,
  but it rewrites style the prompt leaves alone.
- **LFM2.5-8B-A1B** is a reasoning model: with thinking off in the template it
  still returned its answer in `reasoning_content` and an empty `content`, so no
  output was applied (the 324/335 is the code passes alone). Also hybrid, so no
  prefix reuse. Dropped.
- **Gemma 4 E4B** was probed on 6 calls rather than run on the eval: after the
  ~470-token prefix was cached, a call cost 574–982 ms (prefill ~225 ms for ~25 new
  tokens, decode ~35 ms/token), already slower per call than the Apple model on the
  same text. llama.cpp reported `cache_reuse is not supported by this context`
  (sliding-window attention); the slot still matched the common prefix.

## Conclusion

None of the four is faster than the Apple model at equal or better accuracy. The
per-token decode cost sets the floor: the Apple model runs ~14 ms/token, a 4B Q4
model on this GPU ~30–35 ms/token, and only the 1.2B model matches the Apple
speed, at 64 more failures. With the gate calling a model on a minority of real
dictations, the model's speed matters less than it did; its accuracy on the word
edits matters more, and none of these is better at those edits under this prompt.
