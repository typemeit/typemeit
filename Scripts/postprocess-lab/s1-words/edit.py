# Builds S1-mini with its "write digits" neurons switched off: downloads the
# pinned S1-mini release and zeroes the down_proj column of each neuron in
# neurons.json, so that neuron writes nothing to the residual stream.
# usage: python3 edit.py <out-dir>      (needs torch, transformers, huggingface_hub)
import json, os, shutil, sys, torch
from huggingface_hub import snapshot_download
from transformers import AutoModelForCausalLM

REVISION = "88f6b15896c73bbb13a3b596e0afe8ea0d5150b4"  # superwhisper/s1-mini, the weights the neurons were found in
out = sys.argv[1]
src = snapshot_download("superwhisper/s1-mini", revision=REVISION)
neurons = json.load(open(os.path.join(os.path.dirname(__file__), "neurons.json")))
model = AutoModelForCausalLM.from_pretrained(src, dtype=torch.bfloat16)
with torch.no_grad():
    for layer, n in neurons:
        model.model.layers[layer].mlp.down_proj.weight[:, n] = 0
model.save_pretrained(out)
for f in os.listdir(src):
    if f != "model.safetensors" and not f.startswith(".") and not os.path.exists(os.path.join(out, f)):
        shutil.copy(os.path.join(src, f), out)
print(f"{out}: {len(neurons)} neurons off")
