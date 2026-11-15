"""恢复被关闭打断的工作与会议；全程使用临时存档、禁止模型网络请求。

★客户系统下线后，夹具没法再靠 G.Client 造（旧档的"客户"只是存档文件里的
一行 JSON），所以这里直接手搓**旧版存档**（带 clients/slots/抢单冲突/资金
与声誉），走真实的 snapshot → JSON → restore 路径。
"""
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
        """造一份旧版存档：有一笔被打断的活挂在 flash 身上。"""
        game=G.Game();game.day,game.tick=3,421
        worker=game.workers['flash'];worker.job='interrupted';worker.busy=True
        worker.working=17;worker.order=('goto',('reception',0))
        data=json.loads(json.dumps(SAVE.snapshot(game)))
        data['clients']=[{'id':'interrupted','task':'测试交付流程','kind':'document',
                          'persona':'normal','reward':120,'patience_max':2000,
                          'patience':2000,'slot':0,'served_by':'flash','status':status,
                          'result':result,'grab_tick':0,'pos':[1,12]}]
        data['slots']={'0':'interrupted'}
        data['money'],data['rep'],data['neg_days']=869,59,0
        return data
    def restore(self,data):
        restored=G.Game();result=SAVE.restore(restored,data)
        self.assertTrue(result['ok'],result)
        # 命令即工单：读档一律清空客户与已完成记录（防盗门）
        self.assertFalse(hasattr(restored,'clients'))
        self.assertFalse(hasattr(restored,'finished'))
        with patch.object(API.G,'GAME',restored):response=API.app.test_client().get('/api/state')
        self.assertEqual(response.status_code,200)
        self.assertEqual((restored.day,restored.tick),(3,421))
        self.network_mock.assert_not_called()
        self.threads_mock.assert_not_called()
        return restored
    def test_interrupted_work_is_dropped_but_tick_and_motion_survive(self):
        restored=self.restore(self.source())
        # 命令即工单：读档后无客户，"被打断的工作/放回等待"概念随之消失
        self.assertIsNone(restored.workers['flash'].job)
        self.assertFalse(hasattr(restored,'slots'))
        # 空客户下主循环机制不崩：refresh/move/wander 都能跑
        restored.refresh_paths();restored.move();restored._wander_idle()
        # 员工仍能接令走位：指令被接受并算出可行路径，且真的迈步
        self.assertTrue(restored.command('flash','goto','lounge')['ok'])
        worker=restored.workers['flash'];before=worker.pos
        restored.refresh_paths()
        self.assertTrue(worker.path)
        restored.move()
        self.assertNotEqual(worker.pos,before)
    def test_claim_saved_before_service_thread_is_dropped(self):
        restored=self.restore(self.source(status='等待'))
        # 命令即工单：线程未启动前保存的"认领"随客户一起清空
        self.assertIsNone(restored.workers['flash'].job)
        self.assertEqual(restored.snapshot()['clients'], [])
    def test_delivery_generated_before_return_trip_is_discarded(self):
        restored=self.restore(self.source(result='已经完整生成的交付物'))
        # 命令即工单：返程前已生成的交付物不再保留给验收，随客户一并清空
        self.assertIsNone(restored.workers['flash'].job)
        self.assertNotIn('finished',restored.snapshot())
    def test_existing_approval_and_unclaimed_waiting_orders_are_dropped(self):
        for status in ('待验收','等待'):
            with self.subTest(status=status):
                restored=self.restore(self.source(status=status,result='保留成果'))
                # 命令即工单：待验收/等待订单一律随客户清空，不留 finished 记录
                self.assertIsNone(restored.workers['flash'].job)
                self.assertNotIn('finished',restored.snapshot())
    def test_seat_order_with_no_argument_is_a_valid_snapshot(self):
        game=G.Game();game.day,game.tick=3,421
        game.meeting={'kind':'normal','topic':'周会','phase':'gathering','seated':[],'lines':[]}
        for worker in game.workers.values():worker.order=('seat',None);worker.seat_cmd=True
        restored=self.restore(json.loads(json.dumps(SAVE.snapshot(game))))
        self.assertIsNone(restored.meeting)
        for worker in restored.workers.values():
            self.assertFalse(worker.seat_cmd);self.assertFalse(worker.seated)
            self.assertEqual(worker.order,('goto',('desk',worker.who)))
    def test_old_meeting_is_closed_without_replaying_model_dialogue(self):
        game=G.Game();game.day,game.tick=3,421
        game.meeting={'kind':'blame','topic':'复盘','phase':'talking','seated':['m3'],'lines':[{'who':'m3','text':'旧会议发言'}]}
        game.workers['m3'].seated=True;game.workers['m3'].seat_cmd=True
        restored=self.restore(json.loads(json.dumps(SAVE.snapshot(game))))
        self.assertIsNone(restored.meeting);self.assertFalse(restored.workers['m3'].seated)
    def test_ordinary_destination_order_keeps_its_shape(self):
        game=G.Game();game.day,game.tick=3,421
        game.workers['m3'].order=('goto',('lounge','m3'))
        restored=self.restore(json.loads(json.dumps(SAVE.snapshot(game))))
        self.assertEqual(restored.workers['m3'].order,('goto',('lounge','m3')))
    def test_down_worker_stays_down_when_interrupted_job_is_released(self):
        game=G.Game();game.day,game.tick=3,421
        game.workers['flash'].brain_down=True;game.workers['flash'].brain_reason='额度不足'
        restored=self.restore(json.loads(json.dumps(SAVE.snapshot(game))))
        self.assertTrue(restored.workers['flash'].brain_down)
        self.assertEqual(restored.workers['flash'].acting,'脑袋宕机了')

if __name__=='__main__':
    try:unittest.main(verbosity=2)
    finally:scratch.cleanup()
