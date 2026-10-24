"""build (from cached AssemblyAI responses) -> disagree -> decisions -> score, in a temp dir."""
import contextlib, io, json, os, pathlib, sys, tempfile, unittest
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import assemblyai, asr_eval, store

def aai_response(spoken):
    return {'status': 'completed', 'words': [
        {'text': w, 'start': i * 500, 'end': i * 500 + 400, 'speaker': s} for i, (w, s) in enumerate(spoken)]}

class Pipeline(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        support = pathlib.Path(self.tmp.name) / 'support'
        (support / 'Recordings').mkdir(parents=True)
        (support / 'Recordings' / 'AAAA1111-0000.m4a').write_bytes(b'dictation audio')
        meeting = support / 'Meetings' / 'fixture meeting'
        meeting.mkdir(parents=True)
        (meeting / 'others.m4a').write_bytes(b'others audio')
        (meeting / 'meeting.json').write_text(json.dumps({'tracks': [{'file': 'others.m4a', 'role': 'others'}]}))
        os.environ['TYPEMEIT_SUPPORT_DIR'] = str(support)
        os.environ['ASR_EVAL_DIR'] = str(pathlib.Path(self.tmp.name) / 'ref')
        os.environ.pop('ASSEMBLYAI_API_KEY', None)
        self.dictation = [(w, 'A') for w in 'send it to anna today'.split()]
        self.call = [(w, 'A') for w in 'hello there'.split()] + [(w, 'B') for w in 'hi back to you'.split()]
        for name, labels, spoken in (('AAAA1111-0000.m4a', False, self.dictation), ('others.m4a', True, self.call)):
            path = support / 'Recordings' / name if name.startswith('AAAA') else meeting / name
            store.write_json(assemblyai.cache_path(path, labels), aai_response(spoken))

    def tearDown(self):
        self.tmp.cleanup()

    def run_cmd(self, *argv):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            sys.argv = ['asr_eval.py', *argv]
            asr_eval.main()
        return out.getvalue()

    def test_end_to_end(self):
        self.run_cmd('build')
        clips = store.clips()
        self.assertEqual(sorted(c['id'][:2] for c in clips), ['d-', 'm-'])
        by_kind = {c['kind']: c['id'] for c in clips}
        store.write_json(store.sub('systems/fake') / f"{by_kind['dictation']}.json", {'text': 'Send it to Ann today.'})
        store.write_json(store.sub('systems/fake') / f"{by_kind['meeting']}.json", {'text': 'hello there hi back to you'})
        store.write_json(store.sub('diarizers/fake') / f"{by_kind['meeting']}.json", {'segments': [
            {'startMs': 0, 'endMs': 1000, 'speaker': 'p'}, {'startMs': 1000, 'endMs': 2700, 'speaker': 'q'}]})

        self.assertEqual(self.run_cmd('disagree').strip(), '1 span to check, 0 already decided')
        spans = store.read_jsonl(store.root() / 'review.jsonl')
        self.assertEqual(spans[0]['readings'], [{'text': 'anna', 'systems': ['assemblyai']}, {'text': 'ann', 'systems': ['fake']}])
        self.assertEqual((spans[0]['before'], spans[0]['after']), ('send it to', 'today'))

        unreviewed = self.run_cmd('score')
        self.assertIn('fake           dictation WER 20.00%  (1 error in 5 words, 1 clip)', unreviewed)
        self.assertIn('0 spans hand-checked of 1 that differ', unreviewed)

        span = spans[0]
        (store.root() / 'decisions.jsonl').write_text(json.dumps(
            {'key': span['key'], 'clip': span['clip'], 'start': span['start'], 'end': span['end'], 'text': 'Ann'}) + '\n')
        reviewed = self.run_cmd('score')
        self.assertIn('fake           dictation WER  0.00%', reviewed)
        self.assertIn('1 span hand-checked', reviewed)
        self.assertIn('fake           speakers  ', reviewed)
        self.assertIn('(0 words of 6, right number of people on 1 of 1 clip)', reviewed)

class InsertionSet(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        support = pathlib.Path(self.tmp.name) / 'support'
        meeting = support / 'Meetings' / 'fixture meeting'
        meeting.mkdir(parents=True)
        (meeting / 'others.m4a').write_bytes(b'others audio')
        (meeting / 'meeting.json').write_text(json.dumps({'tracks': [{'file': 'others.m4a', 'role': 'others'}]}))
        os.environ['TYPEMEIT_SUPPORT_DIR'] = str(support)
        os.environ['ASR_EVAL_DIR'] = str(pathlib.Path(self.tmp.name) / 'ref')
        os.environ.pop('ASSEMBLYAI_API_KEY', None)
        spoken = 'we met anna then we left the building together'.split()
        gapped = [{'text': w, 'start': i * 500 + (4000 if i >= 3 else 0), 'end': i * 500 + 400 + (4000 if i >= 3 else 0), 'speaker': 'A'}
                  for i, w in enumerate(spoken)]
        store.write_json(assemblyai.cache_path(meeting / 'others.m4a', True), {'status': 'completed', 'words': gapped})
        self.run_cmd('build')
        self.clip = store.clips()[0]['id']
        store.write_json(store.sub('systems/fluid-ultra') / f'{self.clip}.json',
                         {'text': 'We met Anna, so yeah, then we left the building together, thanks.'})
        store.write_json(store.sub('systems/parakeet') / f'{self.clip}.json', {'text': 'We met Anna, so then we left the building together.'})

    def tearDown(self):
        self.tmp.cleanup()

    def run_cmd(self, *argv):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            sys.argv = ['asr_eval.py', *argv]
            asr_eval.main()
        return out.getvalue()

    def test_set_review_and_summary(self):
        played = []
        asr_eval.play_cut = lambda file, begin, length: played.append((round(begin, 2), round(length, 2)))
        asr_eval.input = lambda prompt='': 'r'
        try:
            self.run_cmd('review', '--set', 'ultra-insertions', '--size', '5')
        finally:
            del asr_eval.input
        built = store.read_json(store.root() / 'ultra-insertions.json')
        self.assertEqual([(i['refIndex'], i['words'], i['gapStartMs'], i['gapEndMs']) for i in built['items']],
                         [(3, ['yeah'], 1400, 5500), (9, ['thanks'], 8400, 8400)])
        self.assertEqual(built['population'], {self.clip: {'spans': 2, 'words': 2}})
        self.assertEqual(played, [(0.4, 6.1), (7.4, 2.0)])
        self.assertEqual(sorted(a['answer'] for a in store.read_jsonl(store.root() / 'ultra-insertions-answers.jsonl')), ['r', 'r'])
        summary = self.run_cmd('review-summary')
        self.assertEqual(summary.splitlines()[0], '2 spans answered of 2: 2 real speech (0 not changing the meaning), 0 speech with wrong words, 0 hallucination (100% of spans, 100% of 2 words)')

if __name__ == '__main__':
    unittest.main()
