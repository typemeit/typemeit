#!/usr/bin/env python3
"""Punctuates each text with pcs_en (1-800-BAD-CODE, ONNX) and sherpa-onnx's
English CNN-BiLSTM, timing each call; writes one {text: punctuated} map per model."""
import json, sys, time, statistics
texts = sorted({json.loads(l) for l in open(sys.argv[1]) if l.strip()})
tag = sys.argv[2]

def run(name, fn):
    fn(texts[0])  # warm-up
    out, ms = {}, []
    for t in texts:
        t0 = time.perf_counter(); out[t] = fn(t); ms.append((time.perf_counter() - t0) * 1000)
    json.dump(out, open(f'map-{tag}-{name}.json', 'w'), indent=1)
    ms.sort()
    print(f'{name:8} n={len(texts)}  p50 {ms[len(ms)//2]:.1f} ms  p95 {ms[int(len(ms)*.95)]:.1f} ms  max {ms[-1]:.1f} ms')
    for t in texts[:4]: print(f'   {out[t][:140]!r}')

from punctuators.models import PunctCapSegModelONNX
pcs = PunctCapSegModelONNX.from_pretrained('pcs_en')
run('pcs', lambda t: ' '.join(pcs.infer([t.lower()])[0]))

import sherpa_onnx
cfg = sherpa_onnx.OnlinePunctuationConfig(model_config=sherpa_onnx.OnlinePunctuationModelConfig(
    cnn_bilstm='sherpa-onnx-online-punct-en-2024-08-06/model.int8.onnx', bpe_vocab='sherpa-onnx-online-punct-en-2024-08-06/bpe.vocab'))
sh = sherpa_onnx.OnlinePunctuation(cfg)
run('sherpa', lambda t: sh.add_punctuation_with_case(t))
