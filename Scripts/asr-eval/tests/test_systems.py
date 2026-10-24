"""Helpers the systems share: vad.split_long's quiet-point cutter and fluid_common.save_timings."""
import os, pathlib, sys, tempfile, unittest
import numpy as np
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import store
from systems import fluid_common, vad

class SplitLong(unittest.TestCase):
    # At 100 samples a second a 50 ms frame is 5 samples, so every cut point below is exact.
    RATE = 100

    def test_short_piece_is_one_window(self):
        piece = np.ones(300, dtype=np.float32)
        windows = list(vad.split_long(piece, max_seconds=10, rate=self.RATE))
        self.assertEqual([len(w) for w in windows], [300])

    def test_cuts_mid_frame_at_the_quietest_frame_of_the_last_search_seconds(self):
        piece = np.ones(2500, dtype=np.float32)
        piece[700:705] = 0
        piece[1402:1407] = 0
        windows = list(vad.split_long(piece, max_seconds=10, search_seconds=5, rate=self.RATE))
        # 702 and 1404 are the middles of the silent frames; with no quiet frame in the third
        # search span the first frame of it is the quietest, so that cut lands at 1404 + 500 + 2.
        self.assertEqual([len(w) for w in windows], [702, 702, 502, 594])
        self.assertTrue(np.array_equal(np.concatenate(windows), piece))

    def test_search_seconds_bounds_where_the_cut_may_fall(self):
        piece = np.ones(1500, dtype=np.float32)
        piece[100:105] = 0
        windows = list(vad.split_long(piece, max_seconds=10, search_seconds=2, rate=self.RATE))
        self.assertEqual([len(w) for w in windows], [802, 698])

class SaveTimings(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        os.environ['ASR_EVAL_DIR'] = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def test_merges_kinds_into_the_existing_file(self):
        path = store.sub('timings') / 'fixture-system.json'
        store.write_json(path, {'dictation': {'clips': ['old']}, 'meeting': {'clips': ['kept']}})
        fluid_common.save_timings('fixture-system', {'dictation': {'clips': ['new']}})
        self.assertEqual(store.read_json(path), {'dictation': {'clips': ['new']}, 'meeting': {'clips': ['kept']}})

    def test_writes_a_new_file(self):
        fluid_common.save_timings('fixture-system', {'meeting': {'clips': []}})
        self.assertEqual(store.read_json(store.sub('timings') / 'fixture-system.json'), {'meeting': {'clips': []}})

if __name__ == '__main__':
    unittest.main()
