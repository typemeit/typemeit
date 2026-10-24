"""The answer record the HTML review writes, and the window it cuts."""
import json, pathlib, sys, tempfile, unittest
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import review_server

ITEM = {'key': 'k1', 'clip': 'm-1-mic', 'words': ['i', 'lost'], 'gapStartMs': 500, 'gapEndMs': 3000, 'before': 'a', 'after': 'b'}

class AnswerLine(unittest.TestCase):
    def test_real_answer_with_note(self):
        self.assertEqual(review_server.answer_line(ITEM, {'key': 'k1', 'answer': 'r', 'note': ' clear '}, now=5),
                         {'key': 'k1', 'clip': 'm-1-mic', 'answer': 'r', 'at': 5, 'note': 'clear'})

    def test_terminal_schema_without_note(self):
        self.assertEqual(review_server.answer_line(ITEM, {'answer': 'h', 'note': '  '}, now=5),
                         {'key': 'k1', 'clip': 'm-1-mic', 'answer': 'h', 'at': 5})

    def test_wrong_words_answer(self):
        self.assertEqual(review_server.answer_line(ITEM, {'answer': 'w'}, now=5),
                         {'key': 'k1', 'clip': 'm-1-mic', 'answer': 'w', 'at': 5})

    def test_doesnt_matter_answer(self):
        self.assertEqual(review_server.answer_line(ITEM, {'answer': 'm'}, now=5)['answer'], 'm')

    def test_pick_answer(self):
        item = dict(ITEM, pick=True, readings=[{'text': 'two'}, {'text': 'few'}])
        self.assertEqual(review_server.answer_line(item, {'answer': 'pick', 'choice': 1}, now=5),
                         {'key': 'k1', 'clip': 'm-1-mic', 'answer': 'pick', 'at': 5, 'choice': 1})
        self.assertEqual(review_server.answer_line(item, {'answer': 'pick', 'choice': -1}, now=5)['choice'], -1)
        self.assertIsNone(review_server.answer_line(item, {'answer': 'pick', 'choice': 2}))
        self.assertIsNone(review_server.answer_line(item, {'answer': 'r'}))

    def test_who_answer(self):
        item = dict(ITEM, who=True)
        self.assertEqual(review_server.answer_line(item, {'answer': 'who', 'choice': 0}, now=5),
                         {'key': 'k1', 'clip': 'm-1-mic', 'answer': 'who', 'at': 5, 'choice': 0})
        self.assertEqual(review_server.answer_line(item, {'answer': 'who', 'choice': -1}, now=5)['choice'], -1)
        self.assertIsNone(review_server.answer_line(item, {'answer': 'who', 'choice': 2}))
        self.assertIsNone(review_server.answer_line(item, {'answer': 'who', 'choice': True}))
        self.assertIsNone(review_server.answer_line(item, {'answer': 'r'}))

    def test_rejects_other_answers(self):
        self.assertIsNone(review_server.answer_line(ITEM, {'answer': 's'}))
        self.assertIsNone(review_server.answer_line(ITEM, 'r'))

    def test_append_is_one_json_line_each(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / 'a.jsonl'
            review_server.append_answer(path, {'key': 'k1', 'answer': 'r'})
            review_server.append_answer(path, {'key': 'k1', 'answer': 'h'})
            self.assertEqual([json.loads(l)['answer'] for l in path.read_text().splitlines()], ['r', 'h'])

class CutWindow(unittest.TestCase):
    def test_context_before_and_after(self):
        self.assertEqual(review_server.cut_window(ITEM, 1.0, 10.0), {'begin': 0.0, 'length': 4.5, 'gapOffset': 0.5, 'gapLength': 2.5})

    def test_long_gap_is_capped(self):
        window = review_server.cut_window({**ITEM, 'gapStartMs': 20000, 'gapEndMs': 40000}, 1.0, 10.0)
        self.assertEqual((window['begin'], window['length'], window['gapOffset'], window['gapLength']), (19.0, 10.0, 1.0, 9.0))

class PartWindow(unittest.TestCase):
    item = {**ITEM, 'who': True, 'samples': [{'startMs': 10000, 'endMs': 15000}, {'startMs': 30000, 'endMs': 34000}]}

    def test_words_alone_with_a_little_either_side(self):
        begin, length = review_server.part_window(self.item, 'tight', 2.5, 10.0)
        self.assertAlmostEqual(begin, 0.3); self.assertAlmostEqual(length, 2.9)

    def test_each_voice_sample(self):
        self.assertEqual(review_server.part_window(self.item, 'voice1', 2.5, 10.0), (30.0, 4.0))

    def test_the_window_with_context(self):
        self.assertEqual(review_server.part_window(self.item, 'window', 2.5, 10.0), (0.0, 7.5))

if __name__ == '__main__':
    unittest.main()
