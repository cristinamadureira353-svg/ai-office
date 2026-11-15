class_name StatsBar
extends Control
## 员工状态条
##
## ★画的是真 Bot 的状态：状态 / 在做什么。
##   不再画体力 / 心情 / 疲劳 / 声望——旧经营玩法停用后那几个数不再变化
##   （疲劳没有增长源、罢工离职不再发生、钱不再进出），继续画它们只会
##   让玩家以为事务所还在算经营账。
##   模型名不在这里画：详情页标题下面已经有一行「模型：xxx」。
##
## ★字段一律防御性读取（worker.get("x", 默认值)）：后端正在改，
##   快照里少一个字段就退到默认值，不崩也不画错。
##   两份数据源：
##     · worker —— /api/state 的员工快照（brain_down / job / working / model …）
##     · bot    —— 员工面板从 bot_panel 推出来的真 Bot 状态
##                 （status / 手上的活标题），没有面板时是空字典。

const W := 230.0          # 单条宽度
const ROW_H := 26.0
const BAR_H := 4.0

const C_DIM := UITheme.TEXT_DIM
const C_TEXT := Color("#c8d2e0")
## 「等你回复 / 等同事 / 已暂停」用紫色，和别处的徽标同一套配色。
const C_WAIT := Color("#B388FF")

var worker: Dictionary = {}
## 真 Bot 的状态：{"status": 状态, "title": 手上的活}
var bot: Dictionary = {}
var _font: Font


func _ready() -> void:
	_font = ThemeDB.fallback_font
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func set_worker(w: Dictionary) -> void:
	worker = w
	queue_redraw()


## 真 Bot 的状态。缺字段不炸：状态条自己会退到 worker 里的兜底字段。
func set_bot(info: Dictionary) -> void:
	bot = info
	queue_redraw()


func total_height() -> float:
	return ROW_H * 2.0 + 4.0


func is_brain_down() -> bool:
	return bool(worker.get("brain_down", false))


## 状态文字：宕机 / 忙碌 / 空闲 / 在线。
## 没有真 Bot 面板时（团队还没初始化），退回这个员工此刻在干什么。
func status_text() -> String:
	if is_brain_down():
		return "脑袋宕机了"
	match str(bot.get("status", "")):
		"running": return "忙碌"
		"queued": return "排队中"
		"waiting_for_tasks": return "等同事"
		"waiting_for_user": return "等你回复"
		"paused": return "已暂停"
		"done": return "已完成"
		"failed": return "失败"
		"cancelled": return "已取消"
		"unknown": return "结果未知"
		"stale": return "未绑定"
		"idle": return "空闲"
	# 没有真 Bot 状态可读：看这个员工手上有没有活。
	if bool(worker.get("working", false)):
		return "忙碌"
	if not str(worker.get("job", "")).is_empty():
		return "忙碌"
	var acting := str(worker.get("acting", ""))
	if acting.is_empty():
		return "在线"
	if acting == "在茶水间休息":
		return "休息中"
	return acting.substr(0, 6)


## 状态的配色：跟游戏里其它徽标同一套（GOOD / WARN / BAD / TEXT_DIM）。
func status_color() -> Color:
	if is_brain_down():
		return UITheme.BAD
	match str(bot.get("status", "")):
		"running", "queued": return UITheme.WARN
		"done": return UITheme.GOOD
		"failed", "unknown": return UITheme.BAD
		"paused", "waiting_for_tasks", "waiting_for_user": return C_WAIT
		"idle", "cancelled", "stale": return UITheme.TEXT_DIM
	return UITheme.GOOD


## 手上的活：真任务标题。没有标题就说清楚在等什么。
func task_text() -> String:
	var title := str(bot.get("title", ""))
	if not title.is_empty():
		return title
	match str(bot.get("status", "")):
		"running": return "在干活"
		"queued": return "在排队"
		"failed": return "这一单砸了"
		"done": return "刚做完一单"
	if bool(worker.get("working", false)):
		return "在干活"
	return "手上没活"


func _draw() -> void:
	if worker.is_empty() and bot.is_empty():
		return
	var x := 0.0
	var y := 4.0
	# 1) 状态：在线 / 忙碌 / 空闲 / 宕机。颜色直接体现，不用点开详情才知道。
	var scol := status_color()
	_row(Vector2(x, y), "状态", status_text(), scol, true)
	y += ROW_H
	# 2) 在做什么：手上那单的真任务标题。
	_row(Vector2(x, y), "在做什么", task_text(), C_TEXT)


func _row(pos: Vector2, label: String, val: String, col: Color, with_bar := false) -> void:
	# 标签列 64px："在做什么" 四个字放得下（40px 会被截成"在…"）。
	UITheme.text_in(self, _font, Rect2(pos, Vector2(64, 20)), label, UITheme.SMALL, C_DIM)
	UITheme.text_in(self, _font, Rect2(pos + Vector2(64, 0), Vector2(W - 64, 20)), val, UITheme.SMALL, col, HORIZONTAL_ALIGNMENT_RIGHT)
	if with_bar:
		UITheme.bar(self, Rect2(pos + Vector2(0, 21), Vector2(W, BAR_H)), 1.0, col)
