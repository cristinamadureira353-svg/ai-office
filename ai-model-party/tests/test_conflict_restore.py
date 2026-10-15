"""隔离验证带抢单冲突的存档；不启动主循环、不调用模型、不写真实存档。"""
from pathlib import Path
import json
import os
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRATCH = tempfile.TemporaryDirectory(prefix='ai-office-conflict-restore-')
ENV_FILE = Path(SCRATCH.name) / 'empty.env'
ENV_FILE.write_text('# isolated test configuration\n')
os.environ['AI_OFFICE_ENV_PATH'] = str(ENV_FILE)
os.environ['AI_OFFICE_SAVE_DIR'] = str(Path(SCRATCH.name) / 'saves')
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'server'))
import requests
import game as G
import game_app as API
import save as SAVE


class ConflictRestoreTests(unittest.TestCase):
    def setUp(self):
        self.network = patch.object(requests.sessions.Session, 'request', side_effect=AssertionError('Paid network is forbidden'))
        self.network.start()
        self.serving = patch.object(G.Game, '_serve_client_thread')
        self.serving.start()
        self.addCleanup(self.network.stop)
        self.addCleanup(self.serving.stop)

    def pending(self):
        game = G.Game()
        game.day, game.tick, game.money, game.rep = 6, 321, 869, 67
        customer = G.Client('把测试流程跑通', 96, 200, 'document', 'normal')
        customer.id, customer.slot, customer.status = 'pending', 2, '冲突中'
        game.clients.append(customer)
        game.slots[2] = customer
        game.conflicts[customer.id] = {
            'client':customer.id, 'a':'flash', 'b':'m3', 'task':customer.task,
            'lines':[{'who':'flash','text':'我先接这单。'},{'who':'m3','text':'我也可以完成。'}],
            'judged':False}
        for who in ('flash', 'm3'):
            game.workers[who].job = customer.id
            game.workers[who].acting = '去理论'
        return game

    def restore(self, data):
        game = G.Game()
        self.assertTrue(SAVE.restore(game, data)['ok'])
        with patch.object(API.G, 'GAME', game):
            response = API.app.test_client().get('/api/state')
        self.assertEqual(response.status_code, 200, 'restoring a pending conflict must not break the entire UI state')
        return game, response.get_json()

    def test_new_save_preserves_contenders_dialogue_and_progress(self):
        source = self.pending()
        data = json.loads(json.dumps(SAVE.snapshot(source)))
        restored, state = self.restore(data)
        self.assertEqual(state['conflicts'][0], source.conflicts_view()[0])
        self.assertEqual((restored.day, restored.tick, restored.money, restored.rep), (6, 321, 869, 67))
        self.assertEqual(restored.workers['m3'].job, 'pending')
        self.assertEqual(restored.workers['flash'].job, 'pending')

    def test_conflict_snapshot_does_not_change_with_later_dialogue(self):
        source = self.pending()
        data = SAVE.snapshot(source)
        source.conflicts['pending']['lines'].append({'who':'flash','text':'后续台词'})
        restored, state = self.restore(data)
        self.assertEqual(len(state['conflicts'][0]['lines']), 2)

    def test_legacy_id_only_save_recovers_from_employee_jobs(self):
        data = SAVE.snapshot(self.pending())
        data.pop('conflict_data', None)
        restored, state = self.restore(data)
        self.assertEqual(set((state['conflicts'][0]['a'], state['conflicts'][0]['b'])), {'m3','flash'})
        self.assertEqual(state['conflicts'][0]['lines'], [])
        self.assertEqual(restored.clients[0].status, '冲突中')

    def test_legacy_missing_contenders_returns_order_to_waiting(self):
        data = SAVE.snapshot(self.pending())
        data.pop('conflict_data', None)
        for worker in data['workers']: worker['job'] = None
        restored, state = self.restore(data)
        self.assertEqual(state['conflicts'], [])
        self.assertEqual(restored.clients[0].status, '等待')
        self.assertIsNone(restored.clients[0].served_by)
        self.assertEqual(restored.clients[0].grab_tick, restored.tick + 90)
        self.assertEqual((state['money'], state['day']), (869, 6))
        _, reopened = self.restore(json.loads(json.dumps(SAVE.snapshot(restored))))
        self.assertEqual(reopened['conflicts'], [])
        self.assertEqual(reopened['clients'][0]['status'], '等待')
        self.assertEqual((reopened['money'], reopened['day']), (869, 6))

    def test_retired_or_down_contender_does_not_resume_conflict(self):
        for field in ('brain_down', 'quit'):
            with self.subTest(field=field):
                data = SAVE.snapshot(self.pending())
                next(w for w in data['workers'] if w['who']=='flash')[field] = True
                restored, state = self.restore(data)
                self.assertEqual(state['conflicts'], [])
                self.assertEqual(restored.clients[0].status, '等待')
                self.assertIsNone(restored.workers['m3'].job)
                if field=='brain_down':
                    self.assertTrue(restored.workers['flash'].brain_down)
                    self.assertEqual(restored.workers['flash'].acting, '脑袋宕机了')

    def test_incomplete_conflict_data_and_missing_customer_release_locks(self):
        for data_value in (None, {'a':'missing','b':'missing'}, {'a':'m3','b':'m3'}):
            with self.subTest(data=data_value):
                data = SAVE.snapshot(self.pending())
                data['conflict_data'] = {'pending':data_value}
                for worker in data['workers']: worker['job'] = None
                restored, state = self.restore(data)
                self.assertEqual(state['conflicts'], [])
                self.assertEqual(restored.clients[0].status, '等待')
        data = SAVE.snapshot(self.pending())
        data['clients'] = []
        restored, state = self.restore(data)
        self.assertEqual(state['conflicts'], [])
        self.assertIsNone(restored.workers['m3'].job)
        self.assertIsNone(restored.workers['flash'].job)

    def test_completed_delivery_is_preserved_when_conflict_id_is_stale(self):
        data = SAVE.snapshot(self.pending())
        data.pop('conflict_data', None)
        data['clients'][0].update(status='待验收', served_by='step5', result='已经完成的测试交付物')
        restored, state = self.restore(data)
        self.assertEqual(state['conflicts'], [])
        self.assertEqual((restored.clients[0].status, restored.clients[0].served_by, restored.clients[0].result),
                         ('待验收', 'step5', '已经完成的测试交付物'))

    def test_every_choice_remains_executable_after_restore(self):
        for kind, winner in [('a','flash'),('b','m3'),('reject',None),('scold',None)]:
            with self.subTest(kind=kind):
                restored, _ = self.restore(SAVE.snapshot(self.pending()))
                with patch.object(API.G, 'GAME', restored):
                    response = API.app.test_client().post('/api/command', json={'action':'judge','arg':'pending','kind':kind})
                self.assertEqual(response.status_code, 200)
                self.assertTrue(response.get_json()['ok'])
                self.assertEqual(restored.clients[0].served_by, winner)
                self.assertEqual(restored.snapshot()['conflicts'], [])


if __name__ == '__main__':
    try:
        unittest.main(verbosity=2)
    finally:
        SCRATCH.cleanup()
