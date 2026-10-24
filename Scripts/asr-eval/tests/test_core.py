import pathlib, sys, unittest
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import core

class Tokens(unittest.TestCase):
    def test_case_punctuation_and_apostrophes(self):
        self.assertEqual(core.tokens("Don’t stop, Anna!"), ["don't", 'stop', 'anna'])

    def test_counted(self):
        self.assertEqual(core.counted(1, 'span'), '1 span')
        self.assertEqual(core.counted(2, 'span'), '2 spans')
        self.assertEqual(core.counted(1200, 'word'), '1,200 words')

class JudgeKey(unittest.TestCase):
    def test_same_span_text_same_key(self):
        self.assertEqual(core.judge_key('we met', ['two', 'few', 'two'], 'weeks ago'), core.judge_key('we met', ['few', 'two'], 'weeks ago'))

    def test_context_changes_key(self):
        self.assertNotEqual(core.judge_key('we met', ['two', 'few'], 'weeks ago'), core.judge_key('we left', ['two', 'few'], 'weeks ago'))

class Disagreements(unittest.TestCase):
    ref = 'the cat sat on the mat today'.split()

    def test_identical_has_no_spans(self):
        self.assertEqual(core.disagreements(self.ref, {'a': list(self.ref)}), [])

    def test_substitution(self):
        spans = core.disagreements(self.ref, {'a': 'the cat sat in the mat today'.split()})
        self.assertEqual(len(spans), 1)
        self.assertEqual((spans[0]['start'], spans[0]['end']), (3, 4))
        self.assertEqual(spans[0]['readings'], {'ref': ['on'], 'a': ['in']})

    def test_insertion_and_deletion(self):
        spans = core.disagreements(self.ref, {'a': 'the cat sat on the big mat'.split()})
        self.assertEqual([(s['start'], s['end']) for s in spans], [(5, 5), (6, 7)])
        self.assertEqual(spans[0]['readings']['a'], ['big'])
        self.assertEqual(spans[1]['readings']['a'], [])

    def test_two_systems_overlapping_blocks_merge(self):
        spans = core.disagreements(self.ref, {'a': 'the cat sat in the mat today'.split(),
                                              'b': 'the cat sat in a mat today'.split()})
        self.assertEqual(len(spans), 1)
        self.assertEqual((spans[0]['start'], spans[0]['end']), (3, 5))
        self.assertEqual(spans[0]['readings']['a'], ['in', 'the'])
        self.assertEqual(spans[0]['readings']['b'], ['in', 'a'])

    def test_system_that_agrees_still_gets_its_reading(self):
        spans = core.disagreements(self.ref, {'a': 'the cat sat in the mat today'.split(), 'b': list(self.ref)})
        self.assertEqual(spans[0]['readings']['b'], ['on'])

    def test_key_changes_with_range_and_words(self):
        self.assertNotEqual(core.span_key('c', self.ref, 3, 4), core.span_key('c', self.ref, 3, 5))
        self.assertEqual(core.span_key('c', self.ref, 3, 4), core.span_key('c', self.ref, 3, 4))

class Fuzz(unittest.TestCase):
    def test_readings_reassemble_each_system(self):
        import random
        rng = random.Random(7)
        vocab = 'a b c d e f g'.split()
        for _ in range(300):
            ref = [rng.choice(vocab) for _ in range(rng.randint(0, 12))]
            systems = {n: [w for w in (ref + [rng.choice(vocab)] * rng.randint(0, 2)) if rng.random() > 0.15] for n in 'xy'}
            for n in 'xy':
                for i in range(len(systems[n])):
                    if rng.random() < 0.15:
                        systems[n][i] = rng.choice(vocab)
            spans = core.disagreements(ref, systems)
            for name in systems:
                rebuilt, cursor = [], 0
                for span in spans:
                    rebuilt += ref[cursor:span['start']] + span['readings'][name]
                    cursor = span['end']
                self.assertEqual(rebuilt + ref[cursor:], systems[name])

class Decisions(unittest.TestCase):
    def test_apply(self):
        ref = 'a b c d e'.split()
        self.assertEqual(core.apply_decisions(ref, {(1, 2): ['x', 'y'], (4, 5): []}), 'a x y c d'.split())
        self.assertEqual(core.apply_decisions(ref, {}), ref)
        self.assertEqual(core.apply_decisions(ref, {(5, 5): ['z']}), 'a b c d e z'.split())

class Wer(unittest.TestCase):
    def test_counts(self):
        self.assertEqual(core.wer_counts('a b c d'.split(), 'a x c'.split()), (2, 4))
        self.assertEqual(core.wer_counts([], []), (0, 0))

class Fillers(unittest.TestCase):
    ref = core.tokens('Well, um, we met Anna. Uh... Hmm, then we left.')
    hyp = core.tokens('we met anna er then we left ah')

    def test_list_and_drop(self):
        self.assertEqual(sorted(core.FILLERS), ['ah', 'er', 'erm', 'hmm', 'mm', 'uh', 'um'])
        self.assertEqual(core.drop_fillers(self.ref), 'well we met anna then we left'.split())

    def test_wer_with_and_without(self):
        self.assertEqual(core.wer_counts(self.ref, self.hyp), (5, 10))
        self.assertEqual(core.wer_counts(core.drop_fillers(self.ref), core.drop_fillers(self.hyp)), (1, 7))

class Breakdown(unittest.TestCase):
    def test_substitution_deletion_insertion(self):
        self.assertEqual(core.wer_breakdown('a b c d e'.split(), 'a x c e'.split()), (1, 1, 0))
        self.assertEqual(core.wer_breakdown('a b c d'.split(), 'a x c d e'.split()), (1, 0, 1))

    def test_empty_sides(self):
        self.assertEqual(core.wer_breakdown([], 'a b'.split()), (0, 0, 2))
        self.assertEqual(core.wer_breakdown('a b'.split(), []), (0, 2, 0))

    def test_sums_to_edit_distance(self):
        ref, hyp = 'the cat sat on the mat today'.split(), 'a cat on the big mat'.split()
        self.assertEqual(sum(core.wer_breakdown(ref, hyp)), core.edit_distance(ref, hyp))

class LoneInsertions(unittest.TestCase):
    ref = 'we met anna then left'.split()

    def test_only_words_neither_other_has(self):
        ultra = 'we met so yeah anna then left now'.split()
        parakeet = 'we met so anna then left'.split()
        self.assertEqual(core.lone_insertions(self.ref, ultra, parakeet), [
            {'refIndex': 2, 'hypStart': 3, 'words': ['yeah']},
            {'refIndex': 5, 'hypStart': 7, 'words': ['now']}])

    def test_agreeing_systems_give_nothing(self):
        self.assertEqual(core.lone_insertions(self.ref, list(self.ref), list(self.ref)), [])

    def test_run_of_two_words_stays_together(self):
        ultra = 'we met anna you know then left'.split()
        self.assertEqual(core.lone_insertions(self.ref, ultra, list(self.ref)), [
            {'refIndex': 3, 'hypStart': 3, 'words': ['you', 'know']}])

class WrongSpeaker(unittest.TestCase):
    words = [{'startMs': i * 1000, 'endMs': i * 1000 + 900, 'speaker': 'A' if i < 6 else 'B'} for i in range(10)]

    def test_relabelled_but_right(self):
        segments = [{'startMs': 0, 'endMs': 6000, 'speaker': 'x'}, {'startMs': 6000, 'endMs': 10000, 'speaker': 'y'}]
        self.assertEqual(core.wrong_speaker(self.words, segments), (0, 10, 2, 2))

    def test_boundary_off_by_one_word(self):
        segments = [{'startMs': 0, 'endMs': 5000, 'speaker': 'x'}, {'startMs': 5000, 'endMs': 10000, 'speaker': 'y'}]
        self.assertEqual(core.wrong_speaker(self.words, segments), (1, 10, 2, 2))

    def test_merged_speakers_are_wrong(self):
        segments = [{'startMs': 0, 'endMs': 10000, 'speaker': 'x'}]
        self.assertEqual(core.wrong_speaker(self.words, segments), (4, 10, 2, 1))

    def test_gap_takes_nearest_segment(self):
        segments = [{'startMs': 0, 'endMs': 2000, 'speaker': 'x'}, {'startMs': 7000, 'endMs': 10000, 'speaker': 'y'}]
        wrong, total, _, _ = core.wrong_speaker(self.words, segments)
        self.assertEqual((wrong, total), (1, 10))

class SpeakerLabels(unittest.TestCase):
    words = WrongSpeaker.words

    def test_each_word_gets_the_matched_reference_speaker(self):
        segments = [{'startMs': 0, 'endMs': 4000, 'speaker': 'x'}, {'startMs': 4000, 'endMs': 10000, 'speaker': 'y'}]
        self.assertEqual(core.speaker_labels(self.words, segments), (['A'] * 4 + ['B'] * 6, 2))

    def test_a_label_beyond_the_reference_count_matches_nothing(self):
        segments = [{'startMs': 0, 'endMs': 6000, 'speaker': 'x'}, {'startMs': 6000, 'endMs': 9000, 'speaker': 'y'},
                    {'startMs': 9000, 'endMs': 10000, 'speaker': 'z'}]
        self.assertEqual(core.speaker_labels(self.words, segments), (['A'] * 6 + ['B'] * 3 + [None], 3))

class DisputedStretches(unittest.TestCase):
    def test_consecutive_words_with_the_same_disagreement_are_one_stretch(self):
        a = ['A', 'A', 'A', 'A', 'B', 'A', 'A']
        b = ['A', 'B', 'B', 'A', 'A', 'B', 'A']
        self.assertEqual(core.disputed_stretches(a, b), [
            {'start': 1, 'end': 3, 'a': 'A', 'b': 'B'},
            {'start': 4, 'end': 5, 'a': 'B', 'b': 'A'},
            {'start': 5, 'end': 6, 'a': 'A', 'b': 'B'}])

    def test_a_word_one_side_gives_to_nobody_is_left_out(self):
        self.assertEqual(core.disputed_stretches(['A', None, 'A'], ['B', 'B', 'B']), [
            {'start': 0, 'end': 1, 'a': 'A', 'b': 'B'}, {'start': 2, 'end': 3, 'a': 'A', 'b': 'B'}])

class VoiceSample(unittest.TestCase):
    # A speaks 0-6 s and 20-30 s, B 6-20 s; one word a second.
    words = [{'startMs': i * 1000, 'endMs': i * 1000 + 900, 'speaker': 'B' if 6 <= i < 20 else 'A'} for i in range(30)]
    labels = [w['speaker'] for w in words]

    def test_nearest_agreed_run_cut_to_the_maximum(self):
        self.assertEqual(core.voice_sample(self.words, self.labels, self.labels, 'A', 18000, 4000, 5000, 600), (20000, 25000))
        self.assertEqual(core.voice_sample(self.words, self.labels, self.labels, 'A', 2000, 4000, 5000, 600), (0, 5000))

    def test_words_a_diarizer_disputes_split_the_run(self):
        b = list(self.labels); b[23] = 'B'
        self.assertEqual(core.voice_sample(self.words, self.labels, b, 'A', 18000, 4000, 5000, 600), (24000, 29000))

    def test_no_run_long_enough(self):
        self.assertIsNone(core.voice_sample(self.words, self.labels, self.labels, 'A', 0, 11000, 12000, 600))

if __name__ == '__main__':
    unittest.main()
