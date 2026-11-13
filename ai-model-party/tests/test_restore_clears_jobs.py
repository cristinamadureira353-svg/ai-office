"""读档不能留下悬空 job：客户清空后，员工手上的活必须一起作废。

真实 bug（server/save.py restore()）：restore 清空 game.clients 后，员工的 job
仍指向那个已经消失的客户 id。主循环里 w.job 是一路闸门——不接新单（_auto_grab
只挑 job 为空的人）、不算空闲（_wander_idle 跳过有活的人）、活干完了也找不到
对应客户——表现就是站在工位上一动不动，永远"有活"，永不解雇。

修法：清空客户后，把 job/working/need/busy/eff 和去接待处的 order 一起作废。
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


class RestoreClearsJobsTests(unittest.TestCase):
    def make_game_with_open_job(self):
        game = G.Game()
        game.day, game.money, game.rep, game.tick = 3, 869, 59, 421
        client = G.Client(task="读档前没干完的活", reward=120, patience=2000, need=40)
        client.id = "stale-job"          # 固定 id，才能断言 job 指向的就是它
        client.slot = 0
        client.status = "服务中"
        client.served_by = "flash"
        game.clients.append(client)
        game.slots[0] = client
        worker = game.workers["flash"]
        worker.job = client.id
        worker.working = 17.5
        worker.need = 40
        worker.busy = True
        worker.eff = 0.82
        worker.order = ("goto", ("reception", 0))   # 去接待处接/送这个客户
        return game, worker

    def test_fixture_really_saves_a_job_pointing_at_the_client(self):
        # 前置：夹具确实做出了「job 指向一个客户」的存档，否则下面的断言是空的。
        game, _ = self.make_game_with_open_job()
        data = save_roundtrip(game)
        saved = {w["who"]: w for w in data["workers"]}["flash"]
        self.assertEqual(saved["job"], "stale-job")
        self.assertEqual([c["id"] for c in data["clients"]], ["stale-job"])

    def test_restore_drops_job_of_deleted_client(self):
        game, _ = self.make_game_with_open_job()
        restored = G.Game()
        result = SAVE.restore(restored, save_roundtrip(game))
        self.assertTrue(result["ok"], result)
        self.assertEqual(restored.clients, [])
        self.assertEqual(restored.slots, {})
        worker = restored.workers["flash"]
        self.assertIsNone(worker.job)            # ← 悬空引用必须作废
        self.assertEqual(worker.working, 0)
        self.assertFalse(worker.busy)
        self.assertIsNone(worker.order)          # ← 去接待处的指令一起撤
        self.assertEqual(worker.need, 0)
        self.assertEqual(worker.eff, 1.0)
        self.assertEqual(worker.acting, "在工位待命")

    def test_main_loop_advances_after_restore(self):
        # game.tick 是整数计数器（game.py reset(): self.tick = 0），不是方法；
        # 主循环 loop() 是阻塞 while，单帧推进就是 refresh_paths/move/_wander_idle
        # （与 test_live_restore.py 同款）。这一条就是"读档后主循环不炸、人不再有活"。
        game, _ = self.make_game_with_open_job()
        restored = G.Game()
        SAVE.restore(restored, save_roundtrip(game))
        restored.tick += 1
        restored.refresh_paths()
        restored.move()
        restored._wander_idle()
        self.assertIsNone(restored.workers["flash"].job)


if __name__ == "__main__":
    unittest.main(verbosity=2)
