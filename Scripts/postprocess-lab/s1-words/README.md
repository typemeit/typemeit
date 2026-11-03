# S1-mini without digits

S1-mini (Superwhisper's 0.6B clean-up model, Qwen3-0.6B fine-tune, Apache 2.0
plus a naming clause) failed 65 of 335 eval cases in the A2S1 run. 46 of those
were one behaviour: it writes spoken numbers as digits whatever the digits
style says. type me it turns numbers into digits in code when the style is on,
so the model should never do it.

This edit switches off 128 MLP neurons (131,072 weights, 0.022% of the model)
by zeroing their `down_proj` columns. No training: the neurons were found by
reading the model, after the weight-space programming idea in
https://rikiyat.github.io/blog/weight-space-programming/.

## How the neurons were found

Scripts in `discovery/`, run from an empty work directory with
`S1_MODEL=<s1-mini dir>`; checked on a 4-core CPU in float32.

1. `synth.py`: 260 invented dictations with spoken numbers, 180 to search on
   and 80 held out.
2. `collect.py`: the model writes digits as a bare space token (220) followed
   by digit tokens, so the decision is one token. It collects the hidden
   states where the model is about to write digits (158) or a number word (65).
3. Removing the digits-minus-words direction (`ablate.py`) made it worse
   (84 → 91 outputs with digits): the words it keeps are mostly small counts,
   so the direction also meant "small number".
4. `attrib.py`: gradient × activation for every MLP neuron in layers 8–27 on
   logit(digit) − logit(best number word) at the decision token.
5. `neurons.py`: switch off the top k, skipping neurons whose mean |activation|
   on ordinary output tokens is over 5, and score.

Held-out synthetic dictations plus the 21 eval inputs where S1-mini writes
digits (101), and 40 eval inputs without numbers:

| neurons off | outputs with digits | non-ASCII | input words kept | other outputs changed |
|---|---|---|---|---|
| none | 84 | 3 | 78.5% | 0 of 40 |
| 16 | 46 | 2 | 87.0% | 3 |
| 32 | 21 | 2 | 91.5% | 4 |
| 64 | 7 | 0 | 95.1% | 4 |
| 128 | 1 | 0 | 97.3% | 5 |

Banning the digit tokens at decode time instead fixes 15 of the 21 eval
inputs and breaks 6: "$三千五 dollars", "£一百二十", "The 'June' works for me",
"nineam". The model still wants a numeral and finds another way out; the edit
removes the wish.

## What it costs

On all 145 eval inputs: 20 of the 21 number cases keep the spoken words (the
phone number stays digits). 17 of the other 124 outputs change. Some are closer
to what was said ("Blebird" instead of "BluDDer", "type me it" kept). Some are
worse: digits in the input become words ("8 people" → "eight people"),
"C-E-O", a lost pair of quotes, "repo" → "repos". It no longer fixes
"there house" to "their house".

## Score it

`./eval.sh` on a Mac with `llama-server`: builds the original and the edited
model as Q8_0 GGUF the same way, and runs the A2S1 variant on each. Results
in `build/postprocess-lab/out/s1-original` and `s1-words`.

`python3 edit.py <dir>` builds the edited model alone.
