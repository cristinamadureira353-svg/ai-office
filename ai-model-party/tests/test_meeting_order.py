"""Exercise the meeting consumer of Jev results without model requests."""
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'server'))
import game as G


class MeetingOrderTests(unittest.TestCase):
    def setUp(self):
        self.game = G.Game()
        self.game.meeting = {'kind': 'blame', 'phase': 'seated', 'lines': []}
        self.game.failures = [{'task': 'Synthetic test task', 'why': 'Timed out', 'who': 'flash'}]
        self.spoken = []
        self.network = patch('requests.sessions.Session.request', side_effect=AssertionError('Network forbidden'))
        self.speak = patch.object(G.BG, 'speak', side_effect=self.record_speaker)
        self.network.start()
        self.speak.start()
        self.addCleanup(self.network.stop)
        self.addCleanup(self.speak.stop)

    def record_speaker(self, who, *args, **kwargs):
        self.spoken.append(who)
        return {'who': who, 'text': 'Synthetic reply', 'blames': []}

    def test_jev_pick_becomes_actual_first_speaker(self):
        with patch.object(G.S, '_ask_jev', return_value='step5'):
            self.game._blame_dialogue()
        self.assertEqual(self.spoken[0], 'step5')
        self.assertCountEqual(self.spoken, G.S.ORDER)

    def test_complete_returned_order_is_preserved(self):
        sequence = list(reversed(G.S.ORDER))
        with patch.object(G.S, 'jev_order', return_value=sequence):
            self.game._blame_dialogue()
        self.assertEqual(self.spoken, sequence)

    def test_missing_jev_uses_local_order(self):
        with patch.object(G.S, 'jev_order', return_value=None):
            self.game._blame_dialogue()
        self.assertEqual(self.spoken, G.S.ORDER)

    def test_unavailable_employees_are_not_offered_to_jev(self):
        self.game.workers['m3'].brain_down = True
        self.game.workers['flash'].quit = True
        with patch.object(G.S, 'jev_order', return_value=None) as choose:
            self.game._blame_dialogue()
        self.assertEqual(choose.call_args.kwargs['pool'], ['longcat', 'kimi', 'step5'])
        self.assertEqual(self.spoken, ['longcat', 'kimi', 'step5'])

    def test_all_unavailable_skips_jev(self):
        for worker in self.game.workers.values():
            worker.brain_down = True
        with patch.object(G.S, 'jev_order') as choose:
            self.game._blame_dialogue()
        choose.assert_not_called()
        self.assertEqual(self.spoken, [])

    def test_late_decision_cannot_replace_a_new_meeting(self):
        replacement = {'kind': 'normal', 'phase': 'seated', 'lines': []}

        def replace_meeting(*args, **kwargs):
            self.game.meeting = replacement
            return list(reversed(G.S.ORDER))

        with patch.object(G.S, 'jev_order', side_effect=replace_meeting):
            self.game._blame_dialogue()
        self.assertEqual(self.spoken, [])
        self.assertEqual(replacement['phase'], 'seated')


if __name__ == '__main__':
    unittest.main(verbosity=2)
