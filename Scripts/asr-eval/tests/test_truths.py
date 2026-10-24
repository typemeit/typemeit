"""Truths settle spans by clip and time; the vault round-trips under its key and refuses any other."""
import os, pathlib, secrets, sys, unittest
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import asr_eval, vault
from cryptography.exceptions import InvalidTag

SPAN = {'readings': {'ref': ['few'], 'fluid-ultra': ['two'], 'parakeet': ['few']}}

class SettledReading(unittest.TestCase):
    def test_overlapping_truth_with_a_matching_reading_settles(self):
        truth = {'startMs': 1000, 'endMs': 1200, 'said': 'two'}
        self.assertEqual(asr_eval.settled_reading(SPAN, 1100, 1300, [truth]), ['two'])

    def test_truth_elsewhere_in_the_clip_does_not(self):
        truth = {'startMs': 9000, 'endMs': 9200, 'said': 'two'}
        self.assertIsNone(asr_eval.settled_reading(SPAN, 1100, 1300, [truth]))

    def test_truth_whose_words_no_reading_has_does_not(self):
        truth = {'startMs': 1000, 'endMs': 1200, 'said': 'ten'}
        self.assertIsNone(asr_eval.settled_reading(SPAN, 1100, 1300, [truth]))

    def test_unknown_truth_does_not(self):
        truth = {'startMs': 1000, 'endMs': 1200, 'said': None}
        self.assertIsNone(asr_eval.settled_reading(SPAN, 1100, 1300, [truth]))

class SaidByAnswer(unittest.TestCase):
    pick = {'readings': [{'text': 'two'}, {'text': 'few'}], 'words': []}
    insertion = {'words': ['we', 'left']}

    def test_pick(self):
        self.assertEqual(asr_eval.said_by_answer(self.pick, {'answer': 'pick', 'choice': 1}), 'few')
        self.assertIsNone(asr_eval.said_by_answer(self.pick, {'answer': 'pick', 'choice': -1}))

    def test_insertion_answers(self):
        self.assertEqual(asr_eval.said_by_answer(self.insertion, {'answer': 'r'}), 'we left')
        self.assertEqual(asr_eval.said_by_answer(self.insertion, {'answer': 'm'}), 'we left')
        self.assertEqual(asr_eval.said_by_answer(self.insertion, {'answer': 'h'}), '')
        self.assertIsNone(asr_eval.said_by_answer(self.insertion, {'answer': 'w'}))

class Seal(unittest.TestCase):
    def test_round_trip(self):
        secret = secrets.token_bytes(32)
        self.assertEqual(vault.open_sealed(vault.seal(b'said: two', secret), secret), b'said: two')

    def test_other_key_is_refused(self):
        with self.assertRaises(InvalidTag):
            vault.open_sealed(vault.seal(b'said: two', secrets.token_bytes(32)), secrets.token_bytes(32))

if __name__ == '__main__':
    unittest.main()
