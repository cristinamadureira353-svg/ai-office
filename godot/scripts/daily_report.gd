class_name DailyReport
extends Control
## 每日结算面板（DESIGN 9.2 / 7.2）
## 收支明细 + 五人表现 + 明日安排。数据来自 state.last_settle。
## 没数据时给占位，不显示空白（DEV_PLAN M2-9 用例 3）。

signal closed()

const W := 440.0

var settle: Dictionary = {}
var day := 0
var money := 0
var rep := 0
var workers: Array = []
var game_over := ""
var _font: Font
var _close: Rect2
var _hover_close := false


func _ready() -> void:
	_font = ThemeDB.fallback_font
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false


func update_from(d: Dictionary) -> void:
	var s: Dictionary = UITheme.dict_of(d, "last_settle")
	# 只在真的有新结算时弹出来
	if not s.is_empty() and s != settle:
		settle = s
		visible = true
	day = int(d.get("day", 0))
	money = int(d.get("money", 0))
	rep = int(d.get("rep", 0))
	game_over = UITheme.str_of(d, "game_over")
	workers = d.get("workers", [])
	queue_redraw()


func _panel_rect() -> Rect2:
	var extra := (36 if not UITheme.arr_of(settle, "strikes").is_empty() else 0) + (36 if not UITheme.arr_of(settle, "quits").is_empty() else 0) + (54 if not game_over.is_empty() else 0)
	var h := 296 + workers.size() * 22 + extra
	return Rect2((size.x - W) * .5, (size.y - h) * .5, W, h)


func _draw() -> void:
	if not visible:
		return
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.02, 0.03, 0.05, 0.76))
	var r := _panel_rect()
	UITheme.panel(self, r, UITheme.BG, UITheme.WARN if not game_over.is_empty() else UITheme.EDGE)
	var x := r.position.x + 24
	var width := W - 48
	var y := r.position.y + 24
	UITheme.text_in(self, _font, Rect2(x, y, width, 24), "第 %d 天结算" % day, 15, UITheme.WARN)
	y += 30
	if settle.is_empty():
		UITheme.text_in(self, _font, Rect2(x, y, width, 20), "（还没有结算记录）", 12, UITheme.TEXT_DIM)
	else:
		var wi := UITheme.dict_of(settle, "wages")
		for row in [["基本工资", wi.get("wages", 0)], ["加班补贴", wi.get("overtime", 0)], ["团建", wi.get("team_build", 0)], ["合计支出", wi.get("total", 0)]]:
			UITheme.text_in(self, _font, Rect2(x, y, width * .5, 20), str(row[0]), 12, UITheme.TEXT_DIM)
			var amt := int(row[1])
			UITheme.text_in(self, _font, Rect2(x + width * .5, y, width * .5, 20), "-%d 元" % amt if amt > 0 else "—", 12, UITheme.TEXT if amt > 0 else UITheme.TEXT_FAINT, HORIZONTAL_ALIGNMENT_RIGHT)
			y += 22
		y += 6
		UITheme.bar(self, Rect2(x, y, width, 1), 1, UITheme.EDGE_HI)
		y += 14
		UITheme.text_in(self, _font, Rect2(x, y, width, 20), "结余：%d 元 · 声誉 %d" % [money, rep], 12, UITheme.ACCENT)
		y += 28
		for alert in [["今天罢工：", UITheme.arr_of(settle, "strikes")], ["离职：", UITheme.arr_of(settle, "quits")]]:
			if not alert[1].is_empty():
				for line in UITheme.preview_lines(alert[0] + _names(alert[1]), int(width), _font, 11, 2):
					UITheme.text_in(self, _font, Rect2(x, y, width, 18), line, 11, UITheme.BAD)
					y += 18
		UITheme.text_in(self, _font, Rect2(x, y, width, 20), "员工状态", 11, UITheme.TEXT_DIM)
		y += 24
		for w in workers:
			var who := str(w.get("id", ""))
			var note := "体力%d 心情%d 疲劳%d/3" % [int(w.get("stamina", 0)), int(w.get("mood", 0)), int(w.get("fatigue", 0))]
			var col := UITheme.TEXT
			if w.get("quit", false):
				note = "已离职"
				col = UITheme.BAD
			elif w.get("strike", false):
				note = "罢工"
				col = UITheme.BAD
			UITheme.text_in(self, _font, Rect2(x, y, 66, 18), UITheme.name_of(who), 11, UITheme.worker_color(who))
			UITheme.text_in(self, _font, Rect2(x + 78, y, width - 78, 18), note, 11, col)
			y += 22
	if not game_over.is_empty():
		y += 8
		for line in UITheme.preview_lines("游戏结束：" + game_over, int(width), _font, 12, 3):
			UITheme.text_in(self, _font, Rect2(x, y, width, 18), line, 12, UITheme.BAD)
			y += 18
	_close = Rect2(r.end.x - 114, r.end.y - 60, 90, 36)
	UITheme.button(self, _close, _hover_close)
	UITheme.button_text(self, _font, _close, "知道了", 11, UITheme.ACCENT if _hover_close else UITheme.TEXT)


func _names(arr: Array) -> String:
	var out: Array = []
	for w in arr:
		out.append(UITheme.name_of(String(w)))
	return "、".join(out)


func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseMotion:
		var h := _close.has_point(e.position)
		if h != _hover_close:
			_hover_close = h
			queue_redraw()
	elif e is InputEventMouseButton and e.pressed \
			and e.button_index == MOUSE_BUTTON_LEFT and _close.has_point(e.position):
		visible = false
		closed.emit()
		accept_event()


func _input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and (e as InputEventKey).keycode == KEY_ESCAPE \
			and visible:
		visible = false
		closed.emit()
		accept_event()
