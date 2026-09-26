#!/usr/bin/env python3
"""Copies one run's per-case outputs into docs/postprocess-research/results/eval/.
usage: export.py build/postprocess-lab/out/<name> <results-name>"""
import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEST = os.path.join(HERE, '..', '..', '..', 'docs', 'postprocess-research', 'results', 'eval')

rs = json.load(open(os.path.join(sys.argv[1], 'result.json')))
slim = [{'input': r['input'], 'styles': r['styles'], 'output': r['output'], 'pass': r['pass'],
         'wish': r.get('wish') is not None, 'ms': round(r['ms'], 1), 'modelApplied': r['applied']} for r in rs]
with open(os.path.join(DEST, sys.argv[2] + '.json'), 'w') as f:
    json.dump(slim, f, indent=0, ensure_ascii=False)
    f.write('\n')
