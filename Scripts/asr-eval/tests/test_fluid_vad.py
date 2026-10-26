"""fluid-*-vad systems, with the chunker and the fluidasr binary faked."""
import json, os, pathlib, sys, tempfile, unittest
from unittest import mock
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import store
from systems import fluid_common, fluid_ultra_vad

def fake_chunker(argv, check):
    listing, chunk_dir, manifest_path = argv[3], argv[4], argv[5]
    clips = json.load(open(listing))
    json.dump({c['id']: {'paths': [f"{chunk_dir}/{c['id']}-{n}.wav" for n in range(2)], 'vadSeconds': 0.5, 'audioSeconds': 20}
               for c in clips}, open(manifest_path, 'w'))

def fake_fluidasr(argv, check):
    listing, out = argv[-2], argv[-1]
    pieces = json.load(open(listing))
    json.dump({'peakBytes': 1, 'loadSeconds': 2, 'clips': [{'id': p['id'], 'text': p['id'][-1], 'ms': 10} for p in pieces]}, open(out, 'w'))

def fake_run(argv, check):
    (fake_chunker if argv[0] == 'python' else fake_fluidasr)(argv, check)

class FluidVad(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        os.environ['ASR_EVAL_DIR'] = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def test_chunks_go_through_the_binary_and_join_per_clip(self):
        with mock.patch.object(fluid_ultra_vad.cohere, 'prepare', return_value='python'), \
             mock.patch.object(fluid_common, 'binary', return_value='fluidasr'), \
             mock.patch.object(fluid_common, 'wav', side_effect=lambda path, clip_id: path), \
             mock.patch('subprocess.run', side_effect=fake_run) as run:
            texts = fluid_ultra_vad.transcribe([{'id': 'd-1', 'path': 'd.wav'}, {'id': 'm-1', 'path': 'm.wav'}])
        self.assertEqual(texts, {'d-1': '0 1', 'm-1': '0 1'})
        binary_calls = [call.args[0][:2] for call in run.call_args_list if call.args[0][0] == 'fluidasr']
        self.assertEqual(binary_calls, [['fluidasr', 'ultra'], ['fluidasr', 'ultra']])
        self.assertEqual(store.read_json(store.sub('timings') / 'fluid-ultra-vad.json', {})['meeting']['chunks'], {'m-1': 2})

if __name__ == '__main__':
    unittest.main()
