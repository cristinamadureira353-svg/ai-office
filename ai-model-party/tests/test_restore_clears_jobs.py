"""读档不能留下悬空 job：客户清空后，员工手上的活必须一起作废。

真实 bug（server/save.py restore()）：restore 清空 game.clients 后，员工的 job
仍指向那个已经消失的客户 id。主循环里 w.job 是一路闸门——不算空闲
（_wander_idle 跳过有活的人）、闲聊也不触发——表现就是站在工位上一动不动，
永远"有活"，永不解雇。

修法：读档时把 job/working/need/busy/eff 和去接待处的 order 一起作废。

★客户系统整体下线后，夹具没法再靠 G.Client 造（旧档的"客户"只是存档文件里
的一行 JSON），所以这里直接手搓一份**旧版存档**（v1 格式：带 clients/slots/
抢单冲突/资金与声誉），走真实的 snapshot → JSON → restore 路径。
"""
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "server"))
import game as G
import save as SAVE


def save_roundtrip(game):
    """走真实的 snapshot → JSON → restore 路径，和玩家读档走同一份数据。"""
    return json.loads(json.dumps(SAVE.snapshot(game)))


def legacy_save_with_open_job():
    """造一份旧版存档：员工手上有活，指向一个早就不存在的客户。

    旧档才有的字段（clients / slots / conflicts / money / rep / neg_days）
    在新存档里已经不再写了，这里手工补回去——读档必须能吃得下它们。
    """
    game = G.Game()
    game.day, game.tick = 3, 421
    worker = game.workers["flash"]
    worker.job = "stale-job"          # 固定 id，才能断言 job 指向的就是它
    worker.working = 17.5
    worker.need = 40
    worker.busy = True
    worker.eff = 0.82
    worker.order = ("goto", ("reception", 0))   # 去接待处接/送这个客户
    data = save_roundtrip(game)
    data["clients"] = [{
        "id": "stale-job", "task": "读档前没干完的活", "kind": "document",
        "persona": "normal", "reward": 120, "patience_max": 2000,
        "patience": 2000, "slot": 0, "served_by": "flash", "status": "服务中",
        "result": None, "grab_tick": 0, "pos": [1, 12],
    }]
    data["slots"] = {"0": "stale-job"}
    data["conflicts"] = ["stale-job"]
    data["conflict_data"] = {"stale-job": {"a": "flash", "b": "m3", "task": "读档前没干完的活",
                                           "lines": [], "judged": False}}
    data["money"], data["rep"], data["neg_days"] = 869, 59, 0
    return data


class RestoreClearsJobsTests(unittest.TestCase):
    def test_fixture_really_carries_a_job_pointing_at_the_client(self):
        # 前置：夹具确实做出了「job 指向一个客户」的旧档，否则下面的断言是空的。
        data = legacy_save_with_open_job()
        saved = {w["who"]: w for w in data["workers"]}["flash"]
        self.assertEqual(saved["job"], "stale-job")
        self.assertEqual([c["id"] for c in data["clients"]], ["stale-job"])

    def test_new_save_has_no_client_or_economy_fields(self):
        # 新存档不再写客户/资金/声誉这些下线了的东西。
        data = save_roundtrip(G.Game())
        for key in ("clients", "finished", "slots", "conflicts", "money", "rep",
                    "neg_days", "game_over_reason", "failures"):
            self.assertNotIn(key, data, "新存档不该再写 %s" % key)

    def test_restore_drops_job_of_deleted_client(self):
        restored = G.Game()
        result = SAVE.restore(restored, legacy_save_with_open_job())
        self.assertTrue(result["ok"], result)
        worker = restored.workers["flash"]
        self.assertIsNone(worker.job)            # ← 悬空引用必须作废
        self.assertEqual(worker.working, 0)
        self.assertFalse(worker.busy)
        self.assertIsNone(worker.order)          # ← 去接待处的指令一起撤
        self.assertEqual(worker.need, 0)
        self.assertEqual(worker.eff, 1.0)
        self.assertEqual(worker.acting, "在工位待命")

    def test_restore_drops_client_state_entirely(self):
        restored = G.Game()
        SAVE.restore(restored, legacy_save_with_open_job())
        # 客户系统下线：Game 上根本没有 clients/slots/conflicts 这些状态了，
        # 旧档里的客户数据读进来即丢。
        for attr in ("clients", "slots", "conflicts", "finished", "failures"):
            self.assertFalse(hasattr(restored, attr), attr)
        snapshot = restored.snapshot()
        # 快照里只留着两个空的占位数组（Web 原型还在遍历它们），没有别的残留
        self.assertEqual(snapshot["clients"], [])
        self.assertEqual(snapshot["slots"], [])
        self.assertEqual(snapshot["conflicts"], [])
        self.assertNotIn("finished", snapshot)

    def test_restore_ignores_legacy_money_and_rep(self):
        restored = G.Game()
        SAVE.restore(restored, legacy_save_with_open_job())
        # 旧档里的钱和声誉不再被还原（这套账已经下线），墓碑值固定。
        self.assertEqual(restored.money, 0)
        self.assertEqual(restored.rep, 50)
        # 破产机制下线 ⇒ game_over_reason 恒为 None，旧档里的失败原因也被丢掉。
        self.assertIsNone(restored.game_over_reason)

    def test_main_loop_advances_after_restore(self):
        # game.tick 是整数计数器（game.py reset(): self.tick = 0），不是方法；
        # 主循环 loop() 是阻塞 while，单帧推进就是 refresh_paths/move/_wander_idle
        # （与 test_live_restore.py 同款）。这一条就是"读档后主循环不炸、人不再有活"。
        restored = G.Game()
        SAVE.restore(restored, legacy_save_with_open_job())
        restored.tick += 1
        restored.refresh_paths()
        restored.move()
        restored._wander_idle()
        self.assertIsNone(restored.workers["flash"].job)


if __name__ == '__main__':
    unittest.main(verbosity=2)
