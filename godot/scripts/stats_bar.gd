class_name StatsBar
extends Control
## 员工状态条（M2-8）
##
## 画四条动态属性：体力 / 心情 / 疲劳 / 声望，外加在职状态。
## 边界值直接体现在颜色上：体力见底、心情崩了、疲劳满了要罢工、离职，
## 都要一眼看出来——不然玩家只能靠点开详情才知道自己人要崩了。

const W := 230.0          # 单条宽度
const ROW_H := 26.0
const BAR_H := 4.0

const C_BG := Color("#261816")
const C_TRACK := Color("#2a3242")
const C_STAMINA := Color("#06D6A0")
const C_MOOD := Color("#FFD166")
const C_FATIGUE := Color("#FF6B6B")
const C_REP := Color("#7DC6FF")
const C_DIM := UITheme.TEXT_DIM
const C_TEXT := Color("#c8d2e0")

var worker: Dictionary = {}
var _font: Font


func _ready() -> void:
	_font = ThemeDB.fallback_font
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func set_worker(w: Dictionary) -> void:
	worker = w
	queue_redraw()


func stamina_ratio() -> float:
	return clampf(float(worker.get("stamina", 100)) / 100.0, 0.0, 1.0)


func mood_ratio() -> float:
	return clampf(float(worker.get("mood", 70)) / 100.0, 0.0, 1.0)


func fatigue_ratio() -> float:
	return clampf(float(worker.get("fatigue", 0)) / 3.0, 0.0, 1.0)


func rep_ratio() -> float:
	# 声望是事务所层面的，这里画该员工在事务所里的"存在感"：
	# 用他自己的心情 + 效率折算，跟 UI 上其他条保持同一种刻度感
	var eff := float(worker.get("eff", 1.0))
	return clampf(mood_ratio() * eff, 0.0, 1.0)


func is_quit() -> bool:
	return bool(worker.get("quit", false))


func is_striking() -> bool:
	return bool(worker.get("strike", false))


func total_height() -> float:
	return ROW_H * 4.0 + 4.0


func _draw() -> void:
	if worker.is_empty():
		return
	var x := 0.0
	var y := 4.0
	_row(Vector2(x, y), "体力", stamina_ratio(), C_STAMINA,
		 "%d" % int(worker.get("stamina", 100)))
	y += ROW_H
	_row(Vector2(x, y), "心情", mood_ratio(), C_MOOD,
		 "%d" % int(worker.get("mood", 70)))
	y += ROW_H
	# 疲劳越高越红：1 格是橙，2 格红，3 格（要罢工）加个 ⚠
	var fcol := C_FATIGUE
	var ftext := "%d/3" % int(worker.get("fatigue", 0))
	if int(worker.get("fatigue", 0)) >= 3:
		ftext += " ⚠"
	elif int(worker.get("fatigue", 0)) >= 2:
		fcol = Color("#FF9F6B")
	_row(Vector2(x, y), "疲劳", fatigue_ratio(), fcol, ftext)
	y += ROW_H
	_row(Vector2(x, y), "状态", rep_ratio(), C_REP, _status_text())


func _status_text() -> String:
	if worker.get("brain_down", false):
		return "脑袋宕机了"
	if is_quit():
		return "已离职"
	if is_striking():
		return "罢工中"
	var a: String = str(worker.get("acting", ""))
	if a == "在茶水间休息":
		return "休息中"
	return a.substr(0, 5)


func _row(pos: Vector2, label: String, ratio: float, col: Color, val: String) -> void:
	UITheme.text_in(self, _font, Rect2(pos, Vector2(40, 20)), label, UITheme.SMALL, C_DIM)
	UITheme.text_in(self, _font, Rect2(pos + Vector2(48, 0), Vector2(W - 48, 20)), val, UITheme.SMALL, C_TEXT, HORIZONTAL_ALIGNMENT_RIGHT)
	var bar := Rect2(pos + Vector2(0, 21), Vector2(W, BAR_H))
	UITheme.bar(self, bar, ratio, col)
