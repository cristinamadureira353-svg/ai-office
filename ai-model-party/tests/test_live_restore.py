"""恢复被关闭打断的工作与会议；全程使用临时存档、禁止模型网络请求。"""
import json,os,sys,tempfile,unittest
from pathlib import Path
from unittest.mock import patch
scratch=tempfile.TemporaryDirectory(prefix='ai-office-live-restore-')
env=Path(scratch.name)/'empty.env';env.write_text('# isolated test\n')
os.environ['AI_OFFICE_ENV_PATH']=str(env)
os.environ['AI_OFFICE_SAVE_DIR']=str(Path(scratch.name)/'saves')
for key in ('MINIMAX_API_KEY','LONGCAT_API_KEY','KIMI_API_KEY','STEPFUN_API_KEY','OPENROUTER_API_KEY'):os.environ[key]=''
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'server'))
import requests
import game as G,save as SAVE,game_app as API

class LiveRestoreTests(unittest.TestCase):
    def setUp(self):
        self.network=patch.object(requests.sessions.Session,'request',side_effect=AssertionError('Real model requests are forbidden'))
        self.threads=patch.object(G.threading.Thread,'start')
        self.network_mock=self.network.start();self.threads_mock=self.threads.start()
        self.addCleanup(self.network.stop);self.addCleanup(self.threads.stop)
    def source(self,status='服务中',result=None):
        game=G.Game();game.day,game.money,game.rep,game.tick=3,869,59,421
        customer=G.Client('测试交付流程',120,2000,'document','normal')
        customer.id,customer.slot,customer.status,customer.served_by='interrupted',0,status,'flash'
        customer.result=result;game.clients.append(customer);game.slots[0]=customer
        worker=game.workers['flash'];worker.job=customer.id;worker.busy=True;worker.working=17;worker.order=('goto',('reception',0))
        return game
    def restore(self,game):
        data=json.loads(json.dumps(SAVE.snapshot(game)))
        restored=G.Game();result=SAVE.restore(restored,data)
        self.assertTrue(result['ok'],result)
        with patch.object(API.G,'GAME',restored):response=API.app.test_client().get('/api/state')
        self.assertEqual(response.status_code,200)
        self.assertEqual((restored.day,restored.money,restored.rep,restored.tick),(game.day,game.money,game.rep,game.tick))
        self.network_mock.assert_not_called()
        self.threads_mock.assert_not_called()
        return restored
    def test_interrupted_work_returns_to_waiting_without_locked_worker(self):
        restored=self.restore(self.source())
        customer=restored.clients[0];worker=restored.workers['flash']
        self.assertEqual(customer.status,'等待')
        self.assertIsNone(customer.served_by);self.assertIsNone(worker.job);self.assertIsNone(worker.order)
        self.assertFalse(worker.busy);self.assertEqual(worker.working,0)
        self.assertGreater(customer.grab_tick,restored.tick)
    def test_claim_saved_before_service_thread_started_is_released(self):
        restored=self.restore(self.source(status='等待'))
        self.assertIsNone(restored.clients[0].served_by)
        self.assertIsNone(restored.workers['flash'].job)
    def test_delivery_generated_before_return_trip_is_preserved_for_approval(self):
        restored=self.restore(self.source(result='已经完整生成的交付物'))
        customer=restored.clients[0]
        self.assertEqual((customer.status,customer.served_by,customer.result),('待验收','flash','已经完整生成的交付物'))
        self.assertEqual(restored.workers['flash'].job,customer.id)
        self.assertFalse(restored.workers['flash'].busy)
    def test_existing_approval_and_unclaimed_waiting_orders_stay_unchanged(self):
        for status,who,result in [('待验收','flash','保留成果'),('等待',None,None)]:
            with self.subTest(status=status):
                game=self.source(status=status,result=result);game.clients[0].served_by=who
                if who is None:game.workers['flash'].job=None
                restored=self.restore(game)
                self.assertEqual((restored.clients[0].status,restored.clients[0].served_by,restored.clients[0].result),(status,who,result))
    def test_seat_order_with_no_argument_is_a_valid_snapshot(self):
        game=G.Game();game.day,game.money,game.rep,game.tick=3,869,59,421
        game.meeting={'kind':'normal','topic':'周会','phase':'gathering','seated':[],'lines':[]}
        for worker in game.workers.values():worker.order=('seat',None);worker.seat_cmd=True
        restored=self.restore(game)
        self.assertIsNone(restored.meeting)
        for worker in restored.workers.values():
            self.assertFalse(worker.seat_cmd);self.assertFalse(worker.seated)
            self.assertEqual(worker.order,('goto',('desk',worker.who)))
    def test_old_meeting_is_closed_without_replaying_model_dialogue(self):
        game=self.source(status='待验收',result='已经交付的成果')
        game.meeting={'kind':'blame','topic':'复盘','phase':'talking','seated':['m3'],'lines':[{'who':'m3','text':'旧会议发言'}]}
        game.workers['m3'].seated=True;game.workers['m3'].seat_cmd=True
        restored=self.restore(game)
        self.assertIsNone(restored.meeting);self.assertFalse(restored.workers['m3'].seated)
        self.assertEqual(restored.clients[0].result,'已经交付的成果')
    def test_ordinary_destination_order_keeps_its_shape(self):
        game=G.Game();game.day,game.money,game.rep,game.tick=3,869,59,421
        game.workers['m3'].order=('goto',('lounge','m3'))
        restored=self.restore(game)
        self.assertEqual(restored.workers['m3'].order,('goto',('lounge','m3')))
    def test_down_worker_stays_down_when_interrupted_job_is_released(self):
        game=self.source();worker=game.workers['flash'];worker.brain_down=True;worker.brain_reason='额度不足'
        restored=self.restore(game)
        self.assertEqual(restored.clients[0].status,'等待')
        self.assertTrue(restored.workers['flash'].brain_down)
        self.assertEqual(restored.workers['flash'].acting,'脑袋宕机了')

if __name__=='__main__':
    try:unittest.main(verbosity=2)
    finally:scratch.cleanup()
