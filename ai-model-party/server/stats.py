"""氛围数值（M2-8）

四条动态属性（体力/心情/疲劳/声望）+ 每日结算。
本模块**只做计算与判定，不碰游戏状态**——所有函数都是纯函数，
这样边界规则能被逐条测掉，不用起游戏。

★旧经营玩法（假客户、接单、资金/声誉、破产）已随内嵌 Bot 引擎下线，
  这边对应的判定也一并删了：接单门槛（can_accept / accepts_complex）、
  体力效率折算（efficiency / work_need）、疲劳增长（next_fatigue）、
  报酬与声誉涨跌（reward_scale / rep_gain / rep_grab_bonus）、
  团建回血（apply_team_build）都没有调用方了。
  体力、心情、疲劳本身还在用——它们驱动走动、闲聊、休息姿势和罢工离职。
"""

# ── 范围 ────────────────────────────────────────────────────────────────────
STAMINA_MAX = 100
MOOD_MIN, MOOD_MAX = 0, 100
FATIGUE_MAX = 3
REP_MIN, REP_MAX = 0, 100

# ── 阈值（DEV_PLAN M2-8 步骤 2）─────────────────────────────────────────────
SLACK_MOOD = 20         # < 20 摸鱼概率 +50%
STRIKE_FATIGUE = 3      # 疲劳满 → 罢工
QUIT_STRIKE_DAYS = 2    # 罢工连续 2 天 → 离职

# ── 经济（DESIGN 7.2）───────────────────────────────────────────────────────
SALARY_PER_DAY = 20
OVERTIME = 30                                # 每个加班日
TEAM_BUILD = 80                              # 团建
TEAM_BUILD_MOOD = 25                         # 团建全员心情加成

# 初始（DESIGN 7.1）。声誉是只读墓碑：旧玩法下线后不再涨跌，
# 但旧存档的识别还靠它（前端 save_ui.gd 用 INIT_REP 判旧档）。
INIT_REP = 50


def clamp(v, lo, hi):
    return max(lo, min(hi, v))


# ── 体力与心情边界 ──────────────────────────────────────────────────────────
def must_rest(stamina):
    """体力见底 → 强制去休息，不接受任何指令。"""
    return stamina <= 0


def slack_multiplier(mood):
    """心情 < 20 → 摸鱼概率 ×1.5。"""
    return 1.5 if mood < SLACK_MOOD else 1.0


# ── 疲劳与罢工 ──────────────────────────────────────────────────────────────
def should_strike(fatigue):
    return fatigue >= STRIKE_FATIGUE


def should_quit(strike_days):
    """连续罢工几天了。今天罢工后到 2 → 离职。"""
    return strike_days >= QUIT_STRIKE_DAYS


# ── 每日结算 ────────────────────────────────────────────────────────────────
def daily_wages(staff_count):
    """在职人数 × 日薪。人走了工资当然不用发。"""
    return max(0, staff_count) * SALARY_PER_DAY


def daily_settle(money, staff_count, overtime_days=0, team_built=False):
    """一天的开销结算。返回 (新资金, 明细)。"""
    wages = daily_wages(staff_count)
    over = OVERTIME * max(0, overtime_days)
    build = TEAM_BUILD if team_built else 0
    spent = wages + over + build
    return money - spent, {
        "wages": wages, "overtime": over, "team_build": build, "total": spent}


def natural_decay(stamina_dict, mood_dict, rested=(), slackers=()):
    """每日自然衰减：不休息掉体力，心情轻微下滑（不上班心情也不会自己变好）。

    rested 里的人体力回满；slackers 里的是罢工的，体力也回。
    """
    out_s, out_m = {}, {}
    for who, st in stamina_dict.items():
        if who in rested:
            out_s[who] = STAMINA_MAX
        elif who in slackers:
            out_s[who] = clamp(st + 40, 0, STAMINA_MAX)
        else:
            out_s[who] = clamp(st - 6, 0, STAMINA_MAX)
    for who, md in mood_dict.items():
        out_m[who] = clamp(md - 3, MOOD_MIN, MOOD_MAX)
    return out_s, out_m


# ── 失败条件（DESIGN 7.3）───────────────────────────────────────────────────
def bankrupt(money, neg_days):
    """资金 < 0 且持续 3 天。"""
    return money < 0 and neg_days >= 3


def game_over(money, rep, on_duty, neg_days=0):
    """返回失败原因字符串，没失败返回 None。"""
    if len(on_duty) == 0:
        return "全员离职，事务所关门"
    if rep <= REP_MIN:
        return "声誉归零，被行业除名"
    if bankrupt(money, neg_days):
        return "资金为负已经 %d 天，破产了" % neg_days
    return None
