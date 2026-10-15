"""额度耗尽的隔离回归；所有网络与后台线程均以模拟替代。"""
from pathlib import Path
import json
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'server'))
import providers as P
import game as G
import game_app as API
import save as SAVE
import conflict as CF
import banter as BT
import blame_game as BG


class Upstream:
    def __init__(self, status=200, payload=None, chunks=()):
        self.status_code, self.payload, self.chunks = status, payload or {}, chunks
        self.text = json.dumps(self.payload)
        self.closed = False

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        self.closed = True

    def json(self):
        return self.payload

    def iter_lines(self, **_kw):
        for chunk in self.chunks:
            yield 'data: ' + json.dumps(chunk)
        yield 'data: [DONE]'


QUOTA = {'type': 'error', 'who': 'kimi', 'category': 'quota',
         'brain_down': True, 'scope': 'credential', 'message': '脑袋宕机了（额度用完了）'}


class ShutdownTests(unittest.TestCase):
    def setUp(self):
        self.game = G.Game()
        self.net = patch('requests.sessions.Session.request',
                         side_effect=AssertionError('测试禁止真实 API'))
        self.net.start()
        self.addCleanup(self.net.stop)
        self.keys = patch.dict('os.environ', {p['key_env']: 'synthetic-test-key' for p in P.PROVIDERS.values()})
        self.keys.start()
        self.addCleanup(self.keys.stop)

    def test_delivery_quota_has_no_retry_or_fake_result(self):
        with patch.object(P, 'stream_chat', return_value=iter([QUOTA])) as stream:
            events = list(P.deliver_stream('kimi', '写需求'))
        self.assertEqual(stream.call_count, 1)
        self.assertTrue(any(e['type'] == 'error' for e in events))
        self.assertFalse(any(e['type'] == 'deliver' for e in events))

    def test_quota_stops_worker_and_releases_client(self):
        self.game.spawn_client()
        client = self.game.clients[-1]
        worker = self.game.workers['kimi']
        worker.job = client.id
        worker.path = [(17, 10)]
        worker.order = ('goto', ('desk', 'kimi'))
        worker.typing = True
        client.served_by, client.status = 'kimi', '服务中'
        with patch.object(P, 'stream_chat', return_value=iter([QUOTA])):
            list(self.game.model_stream('kimi', '写需求'))
        self.assertTrue(worker.brain_down)
        self.assertEqual(worker.acting, '脑袋宕机了')
        self.assertFalse(worker.path or worker.order or worker.typing or worker.job)
        self.assertEqual(client.status, '等待')
        self.assertIsNone(client.served_by)

    def test_shutdown_worker_rejects_every_normal_action(self):
        worker = self.game.workers['kimi']
        worker.brain_down = True
        worker.acting = '脑袋宕机了'
        for action, arg in [('rest', None), ('goto', 'desk'), ('off', None),
                            ('back', None), ('assign', 'missing')]:
            reply = self.game.command('kimi', action, arg)
            self.assertFalse(reply['ok'], action)
            self.assertIn('脑袋宕机', reply['msg'])
            self.assertIsNone(worker.order)

    def test_upstream_quota_formats_and_transient_errors(self):
        cases = [
            ('longcat', 402, {}, 'quota'),
            ('longcat', 403, {'error': {'code': 'insufficient_quota'}}, 'quota'),
            ('kimi', 429, {'error': {'type': 'exceeded_current_quota_error'}}, 'quota'),
            ('kimi', 429, {'error': {'message': 'usage limit reached'}}, 'quota'),
            ('kimi', 429, {'error': {'code': 'usage_limit_reached'}}, 'quota'),
            ('longcat', 429, {'error': {'code': 'billing_hard_limit_reached'}}, 'quota'),
            ('step5', 402, {'error': {'message': '套餐额度不足'}}, 'quota'),
            ('m3', 200, {'base_resp': {'status_code': 1008}}, 'quota'),
            ('flash', 429, {'error': {'code': 1008}}, 'quota'),
            ('m3', 200, {'base_resp': {'status_code': 1002}}, 'rate_limit'),
            ('longcat', 429, {'error': {'code': 'rate_limit_exceeded'}}, 'rate_limit'),
            ('kimi', 503, {'error': {'message': 'busy'}}, 'temporary'),
            ('kimi', 401, {}, 'auth'),
            ('step5', 404, {}, 'model_unavailable'),
        ]
        for who, status, payload, expected in cases:
            with self.subTest(who=who, status=status, payload=payload):
                ev = P.error_event(who, status, payload)
                self.assertEqual(ev['category'], expected)
                self.assertEqual(ev['brain_down'], expected not in ('rate_limit', 'temporary'))

    def test_error_body_never_reaches_game_or_browser(self):
        secret = 'synthetic-secret-for-regression'
        upstream = Upstream(429, {'error': {'code': 'insufficient_quota', 'message': secret}})
        with patch.object(P.requests, 'post', return_value=upstream):
            events = list(self.game.model_stream('kimi', 'hi'))
        self.assertNotIn(secret, json.dumps(events) + json.dumps(self.game.snapshot()))
        self.assertTrue(upstream.closed)

    def test_successful_stream_still_delivers_real_text(self):
        chunks = [{'base_resp': {'status_code': '0'}, 'choices': [{'delta': {'content': '已完成'}}]}]
        with patch.object(P.requests, 'post', return_value=Upstream(chunks=chunks)):
            events = list(P.deliver_stream('kimi', 'test', stream=self.game.model_stream))
        self.assertEqual([e['text'] for e in events if e['type'] == 'deliver'], ['已完成'])
        self.assertFalse(self.game.workers['kimi'].brain_down)

    def test_quota_in_http_200_sse_is_fatal_and_closes_response(self):
        upstream = Upstream(chunks=[{'choices': [{'delta': {'content': '未完成稿'}}]},
                                   {'error': {'code': 'insufficient_quota'}}])
        with patch.object(P.requests, 'post', return_value=upstream):
            events = list(P.deliver_stream('kimi', 'test', stream=self.game.model_stream))
        self.assertFalse(any(e['type'] == 'deliver' for e in events))
        self.assertTrue(self.game.workers['kimi'].brain_down)
        self.assertTrue(upstream.closed)

    def test_shared_minimax_balance_stops_both_characters_only(self):
        self.game.shutdown_model('m3', P.error_event('m3', 402))
        self.assertEqual({w.who for w in self.game.workers.values() if w.brain_down}, {'m3', 'flash'})
        self.assertEqual(len([e for e in self.game.events if e['kind'] == 'brain_down']), 2)
        self.game.shutdown_model('m3', P.error_event('m3', 402))
        self.assertEqual(len([e for e in self.game.events if e['kind'] == 'brain_down']), 2)

    def test_model_specific_quota_does_not_disable_shared_peer(self):
        ev = P.error_event('m3', 429, {'error': {'message': 'model quota exceeded'}})
        self.game.shutdown_model('m3', ev)
        self.assertTrue(self.game.workers['m3'].brain_down)
        self.assertFalse(self.game.workers['flash'].brain_down)

    def test_shutdown_has_zero_further_calls_from_chat_or_helpers(self):
        self.game.shutdown_model('kimi', QUOTA)
        with patch.object(G, 'GAME', self.game), patch.object(P, 'stream_chat') as api:
            response = API.app.test_client().post('/api/chat', json={'who': 'kimi', 'text': '去休息'})
            self.assertIn('脑袋宕机了', response.get_data(as_text=True))
            list(self.game.model_stream('kimi', 'hi'))
            self.assertEqual(BT.line('kimi', 'hi', stream=self.game.model_stream), '')
            self.assertIsNone(BG.speak('kimi', [], 1, ['kimi'], [], stream=self.game.model_stream))
            api.assert_not_called()

    def test_quota_via_chat_sets_status_without_500(self):
        with patch.object(G, 'GAME', self.game), patch.object(P, 'stream_chat', return_value=iter([QUOTA])) as api:
            response = API.app.test_client().post('/api/chat', json={'who': 'kimi', 'text': 'hi'})
            self.assertEqual(response.status_code, 200)
            self.assertIn('脑袋宕机了', response.get_data(as_text=True))
            self.assertTrue(self.game.workers['kimi'].brain_down)
            self.assertEqual(api.call_count, 1)

    def test_transient_failure_returns_order_without_shutdown(self):
        self.game.spawn_client()
        c = self.game.clients[-1]
        w = self.game.workers['kimi']
        c.served_by, w.job = 'kimi', c.id
        error = P.error_event('kimi', 503)
        with patch.object(self.game, '_await_at', return_value=True), \
                patch.object(P, 'stream_chat', return_value=iter([error])):
            self.game._serve_client_thread(c.id)
        self.assertFalse(w.brain_down)
        self.assertEqual(c.status, '等待')
        self.assertIsNone(c.served_by)
        self.assertFalse(c.result)

    def test_delivery_path_handles_quota_without_acceptance_or_fake_text(self):
        self.game.spawn_client()
        c = self.game.clients[-1]
        c.served_by = 'kimi'
        self.game.workers['kimi'].job = c.id
        with patch.object(self.game, '_await_at', return_value=True), \
                patch.object(P, 'stream_chat', return_value=iter([QUOTA])):
            self.game._serve_client_thread(c.id)
        self.assertEqual(c.status, '等待')
        self.assertEqual(c.result, '')
        self.assertFalse(self.game.accept(c.id, True)['ok'])
        self.assertFalse(self.game.workers['kimi'].worked_today)

    def test_no_motion_autograb_meeting_or_scheduler_for_down_worker(self):
        self.game.shutdown_model('kimi', QUOTA)
        w = self.game.workers['kimi']
        pos = w.pos
        w.path, w.order = [(18, 14)], ('goto', ('desk', 'kimi'))
        self.game.refresh_paths()
        self.game.move()
        self.game._wander_idle()
        self.assertEqual(w.pos, pos)
        self.assertIsNone(w.order)
        with patch('threading.Thread'):
            self.game.start_meeting()
        self.assertFalse(w.seat_cmd)
        self.game.dismiss_meeting()
        self.assertIsNone(w.order)
        self.assertEqual(w.acting, '脑袋宕机了')

    def test_auto_grab_can_only_choose_surviving_worker(self):
        for who in ('m3', 'kimi', 'longcat'):
            self.game.shutdown_model(who, {**QUOTA, 'who': who})
        self.game.spawn_client()
        c = self.game.clients[-1]
        with patch('threading.Thread'), patch.object(CF, 'pick_contenders', return_value=[]):
            self.game._auto_grab(c)
        self.assertEqual(c.served_by, 'step5')

    def test_all_shutdown_has_no_models_or_meetings(self):
        for who in self.game.workers:
            self.game.shutdown_model(who, {**QUOTA, 'who': who})
        with patch.object(P.requests, 'post') as request, patch('threading.Thread') as threads:
            self.game.jev_decide()
            self.game.spawn_client()
            self.game._auto_grab(self.game.clients[-1])
            self.game._maybe_banter()
            self.assertFalse(self.game.start_meeting()['ok'])
        request.assert_not_called()
        threads.assert_not_called()

    def test_conflict_quota_releases_both_jobs_without_fake_argument(self):
        self.game.spawn_client()
        c = self.game.clients[-1]
        with patch('threading.Thread'):
            self.game._start_conflict(c, 'kimi', 'longcat')
        with patch.object(P, 'stream_chat', return_value=iter([QUOTA])) as stream:
            self.game._conflict_thread(c.id, 'kimi', 'longcat')
        self.assertEqual(stream.call_count, 1)
        self.assertEqual(c.status, '等待')
        self.assertFalse(self.game.conflicts)
        self.assertIsNone(self.game.workers['longcat'].job)
        self.assertFalse(self.game.workers['longcat'].brain_down)

    def test_save_restore_and_newday_do_not_reboot_model(self):
        self.game.shutdown_model('kimi', QUOTA)
        snapshot = SAVE.snapshot(self.game)
        other = G.Game()
        self.assertTrue(SAVE.restore(other, snapshot)['ok'])
        w = other.workers['kimi']
        stats = w.stamina, w.mood
        other._advance_day()
        self.assertTrue(w.brain_down)
        self.assertEqual(w.acting, '脑袋宕机了')
        self.assertEqual((w.stamina, w.mood), stats)
        self.assertFalse(other.command('kimi', 'back')['ok'])

    def test_old_saves_default_to_available(self):
        snapshot = SAVE.snapshot(self.game)
        for w in snapshot['workers']:
            for key in ('brain_down', 'brain_reason', 'brain_scope'):
                w.pop(key)
        self.assertTrue(SAVE.restore(self.game, snapshot)['ok'])
        self.assertTrue(all(w.available for w in self.game.workers.values()))

    def test_reboot_is_manual_one_check_and_failure_stays_down(self):
        self.game.shutdown_model('kimi', QUOTA)
        w = self.game.workers['kimi']
        with patch('threading.Thread') as thread:
            self.assertTrue(self.game.command('kimi', 'reboot')['ok'])
            self.assertFalse(self.game.command('kimi', 'reboot')['ok'])
            self.assertEqual(thread.call_count, 1)
        with patch.object(P, 'stream_chat', return_value=iter([QUOTA])) as stream:
            self.game._reboot_thread('kimi', self.game.gen, w.brain_epoch)
        self.assertEqual(stream.call_count, 1)
        self.assertTrue(w.brain_down)
        self.assertFalse(w.brain_checking)

    def test_successful_reboot_restores_shared_credentials_only(self):
        self.game.shutdown_model('m3', P.error_event('m3', 402))
        self.game.shutdown_model('kimi', QUOTA)
        w = self.game.workers['m3']
        with patch.object(P, 'stream_chat', return_value=iter([{'type': 'done', 'got_text': False}])):
            self.game._reboot_thread('m3', self.game.gen, w.brain_epoch)
        self.assertTrue(self.game.workers['m3'].available)
        self.assertTrue(self.game.workers['flash'].available)
        self.assertTrue(self.game.workers['kimi'].brain_down)

    def test_late_output_and_quota_cannot_overwrite_restored_game(self):
        def stream(*_args, **_kwargs):
            self.game.bump_gen()
            yield QUOTA
        with patch.object(P, 'stream_chat', side_effect=stream):
            events = list(P.deliver_stream('kimi', 'old task', stream=self.game.model_stream))
        self.assertFalse(self.game.workers['kimi'].brain_down)
        self.assertFalse(any(e['type'] == 'deliver' for e in events))

    def test_other_worker_can_complete_order_after_quota_failure(self):
        self.game.spawn_client()
        c = self.game.clients[-1]
        c.served_by = 'kimi'
        self.game.workers['kimi'].job = c.id
        self.game.shutdown_model('kimi', QUOTA)
        with patch('threading.Thread'):
            self.assertTrue(self.game.command('longcat', 'assign', c.id)['ok'])
        events = [{'type': 'delta', 'text': '真实替代交付'}, {'type': 'done', 'got_text': True}]
        with patch.object(self.game, '_await_at', return_value=True), patch.object(P, 'stream_chat', return_value=iter(events)):
            self.game._serve_client_thread(c.id)
        self.assertEqual(c.status, '待验收')
        self.assertEqual(c.served_by, 'longcat')
        self.assertTrue(self.game.accept(c.id, True)['ok'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
