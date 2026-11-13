"""团建不能扣钱：界面上早就不显示"资金"，被扣就是看不见的损失。

真实 bug（game.py team_build()）：动作已经改成纯氛围功能，但还扣 80 元，
钱不够时还拒绝。玩家在界面上看不到任何数字变化，只被扣了一笔看不见的钱。

修法：不扣钱、不因钱不够拒绝；心情 +25 的效果保留。
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
        self.assertGreater(before_money, 0)     # 有钱才谈得上"被扣"
        result = game.team_build()
        self.assertTrue(result["ok"], result)
        self.assertEqual(game.money, before_money, "团建不许扣钱")
        for who, w in game.workers.items():
            self.assertEqual(w.mood, min(ST.MOOD_MAX, before_mood[who] + ST.TEAM_BUILD_MOOD))

    def test_team_build_works_with_zero_money(self):
        game = G.Game()
        game.money = 0
        before_mood = {who: w.mood for who, w in game.workers.items()}
        result = game.team_build()
        self.assertTrue(result["ok"], result)   # 不因"钱不够"被拒
        self.assertEqual(game.money, 0)         # 也不会被扣成负数
        for who, w in game.workers.items():
            self.assertEqual(w.mood, min(ST.MOOD_MAX, before_mood[who] + ST.TEAM_BUILD_MOOD))
            self.assertGreater(w.mood, before_mood[who])   # 效果确实保留


if __name__ == "__main__":
    unittest.main(verbosity=2)
