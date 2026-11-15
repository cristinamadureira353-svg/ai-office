"""团建不能扣钱：界面上早就不显示"资金"，被扣就是看不见的损失。

真实 bug（game.py team_build()）：动作已经改成纯氛围功能，但还扣 80 元，
钱不够时还拒绝。玩家在界面上看不到任何数字变化，只被扣了一笔看不见的钱。

修法：不扣钱、不因钱不够拒绝；心情 +25 的效果保留。

★客户系统下线后更进一步：资金与声誉这两笔账整套不存在了，game.py 里
只剩下只读的墓碑属性（money / rep）。团建碰它们就是写只读属性，直接报错。
"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "server"))
import game as G
import stats as ST


class TeamBuildNoMoneyTests(unittest.TestCase):
    def test_team_build_leaves_money_untouched(self):
        game = G.Game()
        before_money = game.money
        before_mood = {who: w.mood for who, w in game.workers.items()}
        result = game.team_build()
        self.assertTrue(result["ok"], result)
        self.assertEqual(game.money, before_money, "团建不许扣钱")
        for who, w in game.workers.items():
            self.assertEqual(w.mood, min(ST.MOOD_MAX, before_mood[who] + ST.TEAM_BUILD_MOOD))

    def test_money_and_rep_are_read_only_tombstones(self):
        """旧经济系统已下线：money / rep 只剩只读墓碑，写它们必须报错。"""
        game = G.Game()
        with self.assertRaises(AttributeError):
            game.money = 123
        with self.assertRaises(AttributeError):
            game.rep = 1

    def test_team_build_works_without_any_fund_state(self):
        """不再有"钱不够"这个前置条件：团建永远成功，效果保留。"""
        game = G.Game()
        before_mood = {who: w.mood for who, w in game.workers.items()}
        result = game.team_build()
        self.assertTrue(result["ok"], result)
        self.assertEqual(game.money, 0)         # 没有资金概念了
        for who, w in game.workers.items():
            self.assertEqual(w.mood, min(ST.MOOD_MAX, before_mood[who] + ST.TEAM_BUILD_MOOD))
            self.assertGreater(w.mood, before_mood[who])   # 效果确实保留


if __name__ == '__main__':
    unittest.main(verbosity=2)
