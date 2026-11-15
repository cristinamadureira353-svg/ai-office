"""旧版存档（带抢单冲突）读档必须干净；不启动主循环、不调用模型、不写真实存档。

★客户系统下线后，抢单冲突已经没有任何来源：旧存档里的冲突数据读进来即丢。
这个文件守的就是这件事——旧档不能把界面拉崩，也不能把"悬空的活"留在人身上。
"""
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
        self.addCleanup(self.network.stop)

    def pending(self):
        """造一份旧版存档：有一笔订单卡在"冲突中"，两名员工被锁在这单上。"""
        game = G.Game()
        game.day, game.tick = 6, 321
        data = json.loads(json.dumps(SAVE.snapshot(game)))
        data['clients'] = [{
            'id': 'pending', 'task': '把测试流程跑通', 'kind': 'document',
            'persona': 'normal', 'reward': 96, 'patience_max': 200,
            'patience': 200, 'slot': 2, 'served_by': None, 'status': '冲突中',
            'result': None, 'grab_tick': 0, 'pos': [1, 12],
        }]
        data['slots'] = {'2': 'pending'}
        data['conflicts'] = ['pending']
        data['conflict_data'] = {'pending': {
            'client': 'pending', 'a': 'flash', 'b': 'm3', 'task': '把测试流程跑通',
            'lines': [{'who': 'flash', 'text': '我先接这单。'},
                      {'who': 'm3', 'text': '我也可以完成。'}],
            'judged': False}}
        data['money'], data['rep'], data['neg_days'] = 869, 67, 0
        for who in ('flash', 'm3'):
            worker = {w['who']: w for w in data['workers']}[who]
            worker['job'] = 'pending'
            worker['acting'] = '去理论'
        return data

    def restore(self, data):
        game = G.Game()
        self.assertTrue(SAVE.restore(game, data)['ok'])
        # 抢单冲突随客户系统下线：Game 上不再有这些状态
        for attr in ('clients', 'slots', 'conflicts', 'finished'):
            self.assertFalse(hasattr(game, attr), attr)
        with patch.object(API.G, 'GAME', game):
            response = API.app.test_client().get('/api/state')
        self.assertEqual(response.status_code, 200, 'restoring a legacy conflict save must not break the entire UI state')
        return game, response.get_json()

    def test_new_save_drops_clients_and_releases_conflict_jobs(self):
        restored, state = self.restore(self.pending())
        # 命令即工单：旧档的抢单冲突随客户一起清掉，两名争抢者从冲突锁定中释放
        self.assertEqual(state['conflicts'], [])
        self.assertEqual(state['clients'], [])
        self.assertIsNone(restored.workers['m3'].job)
        self.assertIsNone(restored.workers['flash'].job)
        # 标量（天数/tick）仍如实还原；钱与声誉不再还原（旧经济系统已下线）
        self.assertEqual((restored.day, restored.tick), (6, 321))
        self.assertEqual((restored.money, restored.rep), (0, 50))

    def test_legacy_conflict_data_is_ignored_entirely(self):
        data = self.pending()
        # 旧档里的台词再完整也不会复活冲突：客户没了，冲突就没有载体
        data['conflict_data']['pending']['lines'].append({'who': 'flash', 'text': '后续台词'})
        _, state = self.restore(data)
        self.assertEqual(state['conflicts'], [])

    def test_legacy_id_only_save_recovers_from_employee_jobs(self):
        data = self.pending()
        data.pop('conflict_data', None)
        restored, state = self.restore(data)
        # 即便旧档只留冲突 id、没有 conflict_data，读档也不会复活任何客户/冲突
        self.assertEqual(state['conflicts'], [])
        self.assertEqual(state['clients'], [])
        self.assertIsNone(restored.workers['m3'].job)
        self.assertIsNone(restored.workers['flash'].job)

    def test_legacy_missing_contenders_drops_order_and_keeps_scalars(self):
        data = self.pending()
        data.pop('conflict_data', None)
        for worker in data['workers']: worker['job'] = None
        restored, state = self.restore(data)
        # 争抢者缺失时旧逻辑把订单放回等待；命令即工单下客户本就被清空
        self.assertEqual(state['conflicts'], [])
        self.assertEqual(state['clients'], [])
        self.assertEqual(state['day'], 6)
        _, reopened = self.restore(json.loads(json.dumps(SAVE.snapshot(restored))))
        self.assertEqual(reopened['conflicts'], [])
        self.assertEqual(reopened['day'], 6)

    def test_retired_or_down_contender_does_not_resume_conflict(self):
        for field in ('brain_down', 'quit'):
            with self.subTest(field=field):
                data = self.pending()
                next(w for w in data['workers'] if w['who'] == 'flash')[field] = True
                restored, state = self.restore(data)
                self.assertEqual(state['conflicts'], [])
                self.assertEqual(state['clients'], [])
                self.assertIsNone(restored.workers['m3'].job)
                if field == 'brain_down':
                    self.assertTrue(restored.workers['flash'].brain_down)
                    self.assertEqual(restored.workers['flash'].acting, '脑袋宕机了')

    def test_incomplete_conflict_data_and_missing_customer_release_locks(self):
        for data_value in (None, {'a': 'missing', 'b': 'missing'}, {'a': 'm3', 'b': 'm3'}):
            with self.subTest(data=data_value):
                data = self.pending()
                data['conflict_data'] = {'pending': data_value}
                for worker in data['workers']: worker['job'] = None
                restored, state = self.restore(data)
                self.assertEqual(state['conflicts'], [])
                self.assertEqual(state['clients'], [])
        data = self.pending()
        data['clients'] = []
        restored, state = self.restore(data)
        self.assertEqual(state['conflicts'], [])
        self.assertIsNone(restored.workers['m3'].job)
        self.assertIsNone(restored.workers['flash'].job)

    def test_completed_delivery_is_discarded_when_conflict_id_is_stale(self):
        data = self.pending()
        data.pop('conflict_data', None)
        data['clients'][0].update(status='待验收', served_by='step5', result='已经完成的测试交付物')
        restored, state = self.restore(data)
        # 命令即工单：即便旧档已有待验收交付物，读档也一律清空，不复活客户/已完成记录
        self.assertEqual(state['conflicts'], [])
        self.assertEqual(state['clients'], [])
        self.assertNotIn('finished', state)

    def test_every_choice_is_gracefully_rejected_after_restore(self):
        for kind in ('a', 'b', 'reject', 'scold'):
            with self.subTest(kind=kind):
                restored, _ = self.restore(self.pending())
                with patch.object(API.G, 'GAME', restored):
                    response = API.app.test_client().post('/api/command', json={'action': 'judge', 'arg': 'pending', 'kind': kind})
                # 冲突已随客户清空，裁决接口对旧冲突 id 必须体面返回 ok=False，不能 500
                self.assertEqual(response.status_code, 200)
                self.assertFalse(response.get_json()['ok'])
                self.assertEqual(restored.snapshot()['conflicts'], [])


if __name__ == '__main__':
    try:
        unittest.main(verbosity=2)
    finally:
        SCRATCH.cleanup()
