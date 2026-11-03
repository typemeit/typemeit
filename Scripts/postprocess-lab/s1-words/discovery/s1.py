import torch, time, json, sys
from transformers import AutoModelForCausalLM, AutoTokenizer
torch.set_num_threads(4)
import os
MODEL = os.environ.get("S1_MODEL", "superwhisper/s1-mini")
SYSTEM = ("You are a text normalizer for speech-to-text transcripts. The input begins "
    "with a control line specifying the styling, structure, and context settings; "
    "clean the transcript to match those settings and output only the cleaned text.")
tok = AutoTokenizer.from_pretrained(MODEL)
model = AutoModelForCausalLM.from_pretrained(MODEL, dtype=torch.float32).eval()
def prompt(t, styling="semi-formal", structure="prose", context="general"):
    m=[{"role":"system","content":SYSTEM},{"role":"user","content":f"[Styling: {styling}] [Structure: {structure}] [Context: {context}]\n{t}"}]
    return tok.apply_chat_template(m, tokenize=False, add_generation_prompt=True, enable_thinking=False)
@torch.no_grad()
def run(t, **kw):
    ids = tok(prompt(t, **kw), return_tensors="pt")
    out = model.generate(**ids, max_new_tokens=int(len(t.split())*1.8)+32, do_sample=False)
    return tok.decode(out[0][ids.input_ids.shape[1]:], skip_special_tokens=True).strip()
