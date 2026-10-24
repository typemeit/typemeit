"""Runs Bark 3.0 Plus's own runner over <items.json> and writes <out.json> in fluidasr's shape
({"clips": [{id, text, ms, audioSeconds}], "loadSeconds", "peakBytes"}). Called by bark_plus.py.
usage: bark_plus_worker.py <model dir> <items.json> <out.json>"""
import importlib.util, json, resource, sys, time
import numpy as np
import soundfile

model_dir, listing, out = sys.argv[1:4]
spec = importlib.util.spec_from_file_location('bark_coreml', f'{model_dir}/bark_coreml.py')
bark_coreml = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bark_coreml)

load_start = time.perf_counter()
transcriber = bark_coreml.Transcriber(model_dir, 'ane')
transcriber.transcribe(np.zeros(bark_coreml.SR, np.float32))
load_seconds = time.perf_counter() - load_start

clips = []
for item in json.load(open(listing)):
    wave, rate = soundfile.read(item['path'], dtype='float32', always_2d=True)
    wave = wave.mean(1)
    start = time.perf_counter()
    text = transcriber.transcribe(wave, rate)
    clips.append({'id': item['id'], 'text': text, 'ms': (time.perf_counter() - start) * 1000, 'audioSeconds': len(wave) / rate})
json.dump({'clips': clips, 'loadSeconds': load_seconds, 'peakBytes': resource.getrusage(resource.RUSAGE_SELF).ru_maxrss}, open(out, 'w'))
