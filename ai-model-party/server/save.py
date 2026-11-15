"""M4-3 存档系统

三件事：**存得全**、**读得回**、**★读档后随机序列可复现**。

## 为什么 RNG 状态是硬指标

游戏里所有"随机"都走 Python 全局 `random`：闲聊说几句、谁往茶水间溜达、
关系值怎么变、复盘会谁先开口…… 如果只存游戏状态、不存 `random.getstate()`，
那么读档之后**下一次掷骰子就和存档时那局完全不是一条时间线**了——
玩家看到的是"同样的局面，但人全换了一批"，这不叫读档，叫重开。

## 快照一致性

游戏主循环和 LLM 线程都在跑，序列化必须持 `game._lock`，
否则会存到"钱已经加了但体力还没扣"的半截状态。

    import save
    save.save_game(g, "第3天手动")            # 手动存
    save.save_game(g, "第4天结算", auto=True)  # 自动存
    d = save.load_game("第3天手动")
    save.restore(g, d)                        # 读档（会停主循环）
"""
import json
import os
import random
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SAVE_DIR = os.environ.get("AI_OFFICE_SAVE_DIR") or os.path.join(ROOT, "data", "saves")

FORMAT = 2        # 存档格式版本。改字段就 +1，读旧档时按版本走兼容分支
# ★v2（客户系统下线）：不再写 money / rep / neg_days / game_over_reason /
#   clients / finished / slots / conflicts / failures / cf_store。
#   v1 的旧存档照样能读：restore() 一律用 .get() 取值，
#   旧档里那些字段读进来就被丢掉（客户相关的状态在读档时清空，见 restore）。


# ── RNG 状态 ────────────────────────────────────────────────────────────────
def _state_to_json(st):
    """random.getstate() 返回 `(3, (625 个 int 的扁平 tuple), gauss_next)`。

    ★第二项是**扁平**的 625 个整数，不是嵌套 tuple——
      我第一版写 `[[x] for x in st[1]]` 想当然当成嵌套，直接
      `TypeError: 'int' object is not iterable`。
      json 只认 list，所以整体转成 list 存，读回来再逐个转回 int。
    """
    return [st[0], list(st[1]), st[2]]


def _state_from_json(d):
    try:
        return (int(d[0]), tuple(int(i) for i in d[1]), d[2])
    except (TypeError, ValueError, IndexError):
        return None


# ── 快照 ────────────────────────────────────────────────────────────────────
def _worker_to_dict(w):
    return {
        "who": w.who,
        "pos": [round(w.pos[0], 3), round(w.pos[1], 3)],
        "stamina": round(w.stamina, 3),
        "mood": round(w.mood, 3),
        "job": w.job,
        "working": w.working,
        "need": w.need,
        "order": list(w.order) if w.order else None,
        "acting": w.acting,
        "busy": w.busy,
        "seated": w.seated,
        "seat_cmd": w.seat_cmd,
        "fatigue": w.fatigue,
        "strike_days": w.strike_days,
        "quit": w.quit,
        "strike": w.strike,
        "eff": w.eff,
        "worked_today": w.worked_today,
        "off_today": w.off_today,
        "brain_down": w.brain_down, "brain_reason": w.brain_reason,
        "brain_scope": w.brain_scope,
    }


def snapshot(game, name="", auto=False, why="") -> dict:
    """把 Game 抓成可 JSON 化的字典。**不持锁**，由调用方决定。"""
    import relations as REL
    return {
        "format": FORMAT,
        "name": name,
        "auto": bool(auto),
        "why": why,
        "saved_at": time.time(),
        "saved_at_str": time.strftime("%Y-%m-%d %H:%M:%S"),
        # 头部
        "day": game.day,
        "tick": game.tick,
        "day_start": game._day_start,
        # ★不再写 money / rep / neg_days / game_over_reason / clients / finished /
        #   slots / conflicts / failures：这套旧模拟经营玩法的数据已经下线，
        #   旧存档里还留着它们（读档时会被丢掉，见 restore 的说明）。
        #   旧存档的识别不靠这些字段：list_saves() 仍然从存档文件里读
        #   "rep"（旧档的声誉不是初始值 50），前端 save_ui.gd 据此提示"旧版存档"。
        # 五人
        "workers": [_worker_to_dict(w) for w in game.workers.values()],
        # 关系矩阵 + 两个冷却表
        "relations": REL.to_dict(),
        # ★冷却表的键是**元组**（banter.mark 写的是 ("p","m3|flash") / ("w","m3")），
        #   json 只认字符串键——原样抄进去会让 /api/newday 直接 500。
        #   这个 bug 单测抓不到：test_save 建的游戏从没人吐槽过，表都是空的；
        #   真打 30 天时只要触发过一次吐槽就必炸。是实玩抓出来的。
        "bt_store": {_tuple_key_to_str(k): v
                     for k, v in game._bt_store.items()},
        "blame_store": dict(game._blame_store),
        # 事件与日志（计划要求最近 100 条）
        "events": list(game.events)[-100:],
        "log": list(game.log)[-100:],
        "banters": list(game.banters)[-6:],
        "last_settle": game.last_settle,
        "meeting": game.meeting,
        # ★RNG 状态：整份存档的核心
        "rng": _state_to_json(random.getstate()),
    }


# ── 还原 ────────────────────────────────────────────────────────────────────
def restore(game, d) -> dict:
    """把存档写回 Game。返回 {"ok":bool, "msg":str}。

    调用方负责先停主循环——否则主循环下一 tick 就会把还原出来的
    位置/路径再算一遍，读档等于没读。
    """
    import relations as REL
    from game import Worker, nearest_passable
    if not isinstance(d, dict) or "format" not in d:
        return {"ok": False, "msg": "这不是一个存档文件"}
    try:
        # ★换代放在最前面：读档一开始，正在跑的所有长线程立刻失效，
        #   后面无论它们走到哪一步，gen_alive() 都会拦住它们写回。
        game.bump_gen()
        game.day = int(d["day"])
        game.tick = int(d.get("tick", 0))
        game._day_start = int(d.get("day_start", 0))
        # ★不再还原 money / rep / neg_days / game_over_reason：
        #   这套旧模拟经营玩法的账已经下线（见 game.py 文件头），新存档也不再写
        #   这些字段。旧存档里残留的值一律丢掉——尤其 game_over_reason：
        #   旧档里存的是"资金为负连续 3 天"这种已经不存在的失败原因，
        #   读回来会让界面显示一句骗人的"游戏结束"。

        game.workers = {}
        for wd in d.get("workers", []):
            w = Worker(wd["who"], nearest_passable(wd["pos"]))
            w.stamina = wd["stamina"]
            w.mood = wd["mood"]
            w.job = wd.get("job")
            w.working = wd.get("working", 0)
            w.need = wd.get("need", 0)
            o = wd.get("order")
            # 移动目标转回 tuple；开会的 seat 指令没有目标参数。
            w.order = (o[0], tuple(o[1]) if o[1] is not None else None) if o else None
            w.acting = wd.get("acting", "")
            w.busy = wd.get("busy", False)
            w.seated = wd.get("seated", False)
            w.seat_cmd = wd.get("seat_cmd", False)
            w.fatigue = wd.get("fatigue", 0)
            w.strike_days = wd.get("strike_days", 0)
            w.quit = wd.get("quit", False)
            w.strike = wd.get("strike", False)
            w.eff = wd.get("eff", 1.0)
            w.worked_today = wd.get("worked_today", False)
            w.off_today = wd.get("off_today", False)
            w.brain_down = bool(wd.get("brain_down", False))
            w.brain_reason = wd.get("brain_reason", "")
            w.brain_scope = wd.get("brain_scope", "model")
            if w.brain_down:
                game._freeze_brain(w)
            game.workers[w.who] = w

        # ★旧存档里带着客户系统的遗产（指向客户的 job、去接待处的指令、
        #   抢单冲突、没送完的交付物……），客户系统下线后这些一律作废。
        #   不作废的话，读完档的人会永远停在"有活"的状态里：
        #   job 指向一个已经不存在的客户，而主循环里 w.job 是一路闸门
        #   （_wander_idle 跳过有活的人、闲聊也不触发），
        #   表现就是站在工位上一动不动，像卡死。
        for w in game.workers.values():
            # 去接待处的指令也是指认某个客户的（玩家只能下工位/茶水间/摸鱼/会议室，
            # 接待处只有接单/送单流程会去）。客户没了，这个目标就不存在了，指令要撤。
            to_reception = (w.order and w.order[0] == "goto" and w.order[1]
                            and w.order[1][0] == "reception")
            if w.job is None and not to_reception:
                continue
            if w.job is not None:
                # job：这单活指向的客户已经不存在了，作废，否则这个人永远"有活"。
                w.job = None
                # working：这一单已干的秒数，跟着这单一起作废。
                w.working = 0
                # need：这一单需要的有效工时，没有单了就不需要。
                w.need = 0
                # busy：正忙标志是跟着这单设的，单没了就不忙了。
                w.busy = False
                # eff：这单开工时的效率（受体力影响），下一单会重新算。
                w.eff = 1.0
            if to_reception:
                # order：去接待处的指令是为接/送这个客户下的，客户没了就不用去了。
                w.order = None
            # 状态标签同步：原来写着"干活中/去接待处"，现在没人可服务了。
            # 宕机的照旧显示"脑袋宕机了"，离职的照旧显示"已离职"。
            if not w.brain_down and not w.quit:
                w.acting = "在工位待命"

        # ★旧存档里的抢单冲突与未完成交付物随之作废：它们全都挂在客户上，
        #   客户系统已经下线，读回来只会变成指向不存在对象的悬空引用。
        REL.from_dict(d.get("relations") or {})
        game._bt_store = {_str_key_to_tuple(k): v
                          for k, v in (d.get("bt_store") or {}).items()}
        game._blame_store = dict(d.get("blame_store") or {})
        game.events = list(d.get("events") or [])
        game.log = list(d.get("log") or [])
        game.banters = list(d.get("banters") or [])
        game.last_settle = d.get("last_settle")
        game.meeting = None
        if d.get("meeting"):
            for w in game.workers.values():
                if w.seat_cmd or w.seated or (w.order and w.order[0] == "seat"):
                    w.seat_cmd, w.seated, w.order = False, False, None
                    if not w.brain_down and not w.quit:
                        w.acting = "散会"
            game.send_all_back()
            game.event("meeting_end", "读档后结束上次会议，可重新召集")

        st = _state_from_json(d.get("rng") or [])
        rng_ok = st is not None
        if rng_ok:
            random.setstate(st)
        return {"ok": True, "msg": "读档完成", "rng_restored": rng_ok}
    except (KeyError, TypeError, ValueError) as e:
        return {"ok": False, "msg": "存档字段缺失或类型不对：%s" % e}


# ── 落盘 ────────────────────────────────────────────────────────────────────
def _safe_name(name):
    """存档名 → 文件名片段。**挡目录穿越，且不留隐藏文件。**

    实测踩过：`../../etc/passwd` 被清洗成 `....etcpasswd_...`——路径穿越确实挡住了
    （没有 `/`），但那一串前导点会让它变成**隐藏文件**，ls 看不见、prune 也照样能删。
    扩展名是存盘时统一加的 `.json`，名字里不需要点，所以干脆一个点都不留。
    """
    keep = []
    for ch in str(name or ""):
        if ch.isalnum() or ch in "-_第天手自动破产离职前存档现场:":
            keep.append(ch)
    out = "".join(keep).strip(" -_:") or "save"
    return out[:48] or "save"


def save_game(game, name="", auto=False, why="") -> str:
    """持锁抓快照并落盘，返回存档 id（文件名去扩展名）。"""
    os.makedirs(SAVE_DIR, exist_ok=True)
    sid = "%s_%d" % (_safe_name(name or "手动存档"), int(time.time() * 1000))
    with game._lock:
        d = snapshot(game, name=name or "手动存档", auto=auto, why=why)
    d["id"] = sid
    path = os.path.join(SAVE_DIR, sid + ".json")
    tmp = path + ".tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(d, f, ensure_ascii=False)
    except TypeError as e:
        # ★存不下来的存档**必须说清楚是哪个字段**，不然 500 只是一句
        #   "keys must be str, ... not tuple"，查的时候完全不知道该看哪。
        bad = _find_bad_key(d)
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise TypeError("%s（问题字段：%s）" % (e, bad or "没定位到")) from e
    os.replace(tmp, path)      # 原子替换：写到一半崩了也不会留半个坏档
    return sid


def _tuple_key_to_str(k):
    """元组键 → 字符串键。用 '␟' 分隔，冷却表的值里不会有这个字符。"""
    if isinstance(k, tuple):
        return "␟".join(str(x) for x in k)
    return str(k)


def _str_key_to_tuple(k):
    """_tuple_key_to_str 的逆操作。"""
    return tuple(str(k).split("␟")) if "␟" in str(k) else k


def _find_bad_key(obj, path="<root>", depth=0):
    """找出第一个 json 存不了的键，返回 '路径 键'。"""
    if depth > 10:
        return None
    if isinstance(obj, dict):
        for k, v in obj.items():
            if not isinstance(k, (str, int, float, bool)) and k is not None:
                return "%s 的键 %r（%s）" % (path, k, type(k).__name__)
            r = _find_bad_key(v, "%s/%s" % (path, k), depth + 1)
            if r:
                return r
    elif isinstance(obj, (list, tuple)):
        for i, v in enumerate(obj):
            r = _find_bad_key(v, "%s[%d]" % (path, i), depth + 1)
            if r:
                return r
    return None


def load_game(sid):
    """读存档。坏档返回 {"ok":False,"msg":...}，**不抛异常**。"""
    path = os.path.join(SAVE_DIR, _safe_name(sid) + ".json")
    if not os.path.exists(path):
        return {"ok": False, "msg": "没有这个存档：%s" % sid}
    try:
        with open(path, encoding="utf-8") as f:
            d = json.load(f)
    except json.JSONDecodeError as e:
        # 判据第 7 条：损坏存档不崩，给友好错误
        return {"ok": False, "msg": "存档文件坏了（第 %d 行）：%s" % (e.lineno, e.msg)}
    except OSError as e:
        return {"ok": False, "msg": "读不了存档：%s" % e}
    if not isinstance(d, dict) or "format" not in d:
        return {"ok": False, "msg": "这不是一个存档文件"}
    d["ok"] = True
    return d


def list_saves():
    """存档列表（给 UI）。坏档也列出来，标 ok=False——不然玩家会以为存档丢了。"""
    out = []
    if not os.path.isdir(SAVE_DIR):
        return out
    for fn in sorted(os.listdir(SAVE_DIR), reverse=True):
        if not fn.endswith(".json"):
            continue
        d = load_game(fn[:-5])
        out.append({
            "id": fn[:-5],
            "ok": bool(d.get("ok")),
            "msg": d.get("msg", ""),
            "name": d.get("name", fn[:-5]),
            "auto": d.get("auto", False),
            "why": d.get("why", ""),
            "day": d.get("day", "?"),
            "money": d.get("money", "?"),
            "rep": d.get("rep", "?"),
            "workers_left": sum(1 for w in (d.get("workers") or [])
                                if not w.get("quit")),
            "saved_at_str": d.get("saved_at_str", ""),
        })
    return out


def prune(keep=40):
    """只留最近 keep 个自动档 + 全部手动档。手动档玩家可能特意留的，不能删。"""
    if not os.path.isdir(SAVE_DIR):
        return 0
    autos = []
    for fn in os.listdir(SAVE_DIR):
        if not fn.endswith(".json"):
            continue
        p = os.path.join(SAVE_DIR, fn)
        try:
            with open(p, encoding="utf-8") as f:
                head = json.load(f)
        except Exception:
            continue
        # ★必须是 dict。存档目录里可能混着坏档（test_save 故意写的截断 JSON、
        #   以及一个纯数组文件），`head.get` 会在 list 上抛 AttributeError，
        #   而 prune 是在**每次自动存档后**都会调的——一个坏档能直接把存档功能打挂。
        if not isinstance(head, dict):
            continue
        if head.get("auto"):
            autos.append((head.get("saved_at", 0), p))
    autos.sort(reverse=True)
    n = 0
    for _, p in autos[keep:]:
        try:
            os.remove(p)
            n += 1
        except OSError:
            pass
    return n
