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
        # 命令即工单：读档一律清空客户（防盗门），旧档里的抢单冲突随之作废
        self.assertEqual(game.clients, [])
        self.assertEqual(game.finished, [])
        self.assertEqual(game.slots, {})
        self.assertEqual(game.conflicts, {})
        with patch.object(API.G, 'GAME', game):
            response = API.app.test_client().get('/api/state')
        self.assertEqual(response.status_code, 200, 'restoring a legacy conflict save must not break the entire UI state')
        return game, response.get_json()

    def test_new_save_drops_clients_and_releases_conflict_jobs(self):
        source = self.pending()
        data = json.loads(json.dumps(SAVE.snapshot(source)))
        restored, state = self.restore(data)
        # 命令即工单：旧档的抢单冲突随客户一起清掉，两名争抢者从冲突锁定中释放
        self.assertEqual(state['conflicts'], [])
        self.assertEqual(state['clients'], [])
        self.assertIsNone(restored.workers['m3'].job)
        self.assertIsNone(restored.workers['flash'].job)
        # 标量（天数/tick/钱/声誉）仍如实还原
        self.assertEqual((restored.day, restored.tick, restored.money, restored.rep), (6, 321, 869, 67))

    def test_conflict_snapshot_does_not_change_with_later_dialogue(self):
        source = self.pending()
        data = SAVE.snapshot(source)
        source.conflicts['pending']['lines'].append({'who':'flash','text':'后续台词'})
        # snapshot 是深拷贝：之后往源冲突追加的台词不进快照（保留原断言力度）
        self.assertEqual(len(data['conflict_data']['pending']['lines']), 2)
        # 读档后旧冲突依旧被清空，不会因为快照里还有台词就复活
        _, state = self.restore(data)
        self.assertEqual(state['conflicts'], [])

    def test_legacy_id_only_save_recovers_from_employee_jobs(self):
        data = SAVE.snapshot(self.pending())
        data.pop('conflict_data', None)
        restored, state = self.restore(data)
        # 即便旧档只留冲突 id、没有 conflict_data，读档也不再复活任何客户/冲突
        self.assertEqual(state['conflicts'], [])
        self.assertEqual(state['clients'], [])
        self.assertIsNone(restored.workers['m3'].job)
        self.assertIsNone(restored.workers['flash'].job)

    def test_legacy_missing_contenders_drops_order_and_keeps_scalars(self):
        data = SAVE.snapshot(self.pending())
        data.pop('conflict_data', None)
        for worker in data['workers']: worker['job'] = None
        restored, state = self.restore(data)
        # 争抢者缺失时旧逻辑把订单放回等待；命令即工单下客户本就被清空
        self.assertEqual(state['conflicts'], [])
        self.assertEqual(state['clients'], [])
        self.assertEqual((state['money'], state['day']), (869, 6))
        _, reopened = self.restore(json.loads(json.dumps(SAVE.snapshot(restored))))
        self.assertEqual(reopened['conflicts'], [])
        self.assertEqual(reopened['clients'], [])
        self.assertEqual((reopened['money'], reopened['day']), (869, 6))

    def test_retired_or_down_contender_does_not_resume_conflict(self):
        for field in ('brain_down', 'quit'):
            with self.subTest(field=field):
                data = SAVE.snapshot(self.pending())
                next(w for w in data['workers'] if w['who']=='flash')[field] = True
                restored, state = self.restore(data)
                self.assertEqual(state['conflicts'], [])
                self.assertEqual(state['clients'], [])
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
                self.assertEqual(state['clients'], [])
        data = SAVE.snapshot(self.pending())
        data['clients'] = []
        restored, state = self.restore(data)
        self.assertEqual(state['conflicts'], [])
        self.assertIsNone(restored.workers['m3'].job)
        self.assertIsNone(restored.workers['flash'].job)

    def test_completed_delivery_is_discarded_when_conflict_id_is_stale(self):
        data = SAVE.snapshot(self.pending())
        data.pop('conflict_data', None)
        data['clients'][0].update(status='待验收', served_by='step5', result='已经完成的测试交付物')
        restored, state = self.restore(data)
        # 命令即工单：即便旧档已有待验收交付物，读档也一律清空，不复活客户/已完成记录
        self.assertEqual(state['conflicts'], [])
        self.assertEqual(state['clients'], [])
        self.assertEqual(restored.clients, [])
        self.assertEqual(restored.finished, [])

    def test_every_choice_is_gracefully_rejected_after_restore(self):
        for kind in ('a', 'b', 'reject', 'scold'):
            with self.subTest(kind=kind):
                restored, _ = self.restore(SAVE.snapshot(self.pending()))
                with patch.object(API.G, 'GAME', restored):
                    response = API.app.test_client().post('/api/command', json={'action':'judge','arg':'pending','kind':kind})
                # 冲突已随客户清空，裁决接口对旧冲突 id 必须体面返回 ok=False，不能 500
                self.assertEqual(response.status_code, 200)
                self.assertFalse(response.get_json()['ok'])
                self.assertEqual(restored.clients, [])
                self.assertEqual(restored.snapshot()['conflicts'], [])


if __name__ == '__main__':
    try:
        unittest.main(verbosity=2)
    finally:
        SCRATCH.cleanup()
