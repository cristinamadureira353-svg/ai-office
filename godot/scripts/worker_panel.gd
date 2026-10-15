class_name WorkerPanel
extends Control
## 角色指令面板（DESIGN 9.2「点角色」）
##
## 左下常驻：列出五个员工的状态条；点一个展开详情和指令。
## 指令：去茶水间 / 去摸鱼 / 开会 / 跟他说话（打开 ChatPanel）。
## 所有可点区域都有悬停反馈，Esc 关闭展开。

signal cmd_requested(who, action, arg)
signal chat_requested(who)
signal selection_changed(who)
signal utility_requested(action)
signal feedback(message)

var workers: Array = []
var selected := ""
var state: Dictionary = {}
var _font: Font
var _bars: Array = []          # {id, rect, data}
var _btns: Array = []          # {id, rect}
var _sb: StatsBar = null
var _hover := ""
var _chat_buttons: Array = []
var _utility_buttons: Array = []
var _disabled_btns: Array = []


func _ready() -> void:
	_font = ThemeDB.fallback_font
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_PASS
	_sb = StatsBar.new()
	add_child(_sb)
	resized.connect(queue_redraw)
	mouse_exited.connect(func():
		_hover = ""
		queue_redraw())


func update_from(d: Dictionary) -> void:
	state = d
	workers = d.get("workers", [])
	queue_redraw()


func select(who: String) -> void:
	selected = "" if selected == who else who
	selection_changed.emit(selected)
	queue_redraw()


func _worker(who: String) -> Dictionary:
	for w in workers:
		if String(w.get("id", "")) == who:
			return w
	return {}


func _draw() -> void:
	_bars.clear()
	_btns.clear()
	_chat_buttons.clear()
	_utility_buttons.clear()
	_disabled_btns.clear()
	var list := _list_rect()
	UITheme.panel(self, list)
	UITheme.text_in(self, _font, Rect2(list.position + Vector2(20, 16), Vector2(312, 24)), "员工 · 点卡片查看指令", UITheme.BODY, UITheme.TEXT)
	UITheme.text_in(self, _font, Rect2(list.position + Vector2(336, 16), Vector2(list.size.x - 628, 24)), "Q/E 切换区域 · O 全景 · C 聊天", UITheme.SMALL, UITheme.TEXT_DIM)
	for i in 2:
		var action: String = ["save", "relations"][i]
		var button := Rect2(list.end.x - 272 + i * 128, list.position.y + 12, 120, 32)
		UITheme.button(self, button, _hover == "utility:" + action)
		UITheme.button_text(self, _font, button, ["存档 F5", "关系 Tab"][i], UITheme.SMALL, UITheme.TEXT)
		_utility_buttons.append({"id":action, "rect":button})
	var card_w := (list.size.x - 40 - 40) / 5
	for i in range(5):
		var r := Rect2(list.position.x + 20 + i * (card_w + 10), list.position.y + 52, card_w, 88)
		var who := String(workers[i].get("id", "")) if i < workers.size() else ""
		if not who.is_empty():
			_draw_row(r, who, who == selected)
	_sb.visible = not selected.is_empty()
	if selected.is_empty():
		return
	_draw_detail(selected)


func _list_rect() -> Rect2:
	return Rect2(24, size.y - 172, size.x - 48, 160)


func _panel_rect() -> Rect2:
	return Rect2(size.x - 396, 76, 380, 468)


func _has_point(point: Vector2) -> bool:
	return _list_rect().has_point(point) or (not selected.is_empty() and _panel_rect().has_point(point))


func _draw_row(r: Rect2, who: String, sel: bool) -> void:
	var w := _worker(who)
	var col := UITheme.worker_color(who)
	var hovered := _hover == "row:" + who
	UITheme.panel(self, r, UITheme.BG if not sel else Color("#1e2636"),
			col if sel else (UITheme.EDGE_HI if hovered else UITheme.EDGE), .22)
	if sel:
		draw_rect(r.grow(-7), Color(col, .12))
		draw_rect(r.grow(-5), col, false, 2)
	_bars.append({"id": "row:" + who, "rect": r})

	UITheme.portrait(self, who, Rect2(r.position + Vector2(12, 12), Vector2(32, 48)))
	var x := r.position.x + 56
	var width := r.size.x - 68
	UITheme.text_in(self, _font, Rect2(x, r.position.y + 10, width - 58, 24), UITheme.name_of(who), UITheme.SMALL, col)
	var chat_rect := Rect2(r.end.x - 62, r.position.y + 8, 50, 30)
	var down := bool(w.get("brain_down", false))
	UITheme.button(self, chat_rect, _hover == "chat:" + who, not down)
	UITheme.button_text(self, _font, chat_rect, "聊天", UITheme.SMALL, UITheme.TEXT_FAINT if down else UITheme.TEXT)
	_chat_buttons.append({"who":who, "rect":chat_rect, "down":down})
	var st := String(w.get("acting", ""))
	if w.get("quit", false):
		st = "已离职"
	elif w.get("strike", false):
		st = "罢工中"
	if w.get("brain_down", false):
		st = "脑袋宕机了"
	UITheme.text_in(self, _font, Rect2(x, r.position.y + 38, width, 22), st, UITheme.SMALL,
			UITheme.BAD if (w.get("quit", false) or w.get("strike", false) or w.get("brain_down", false)) else UITheme.TEXT_DIM)

	UITheme.bar(self, Rect2(Vector2(x, r.position.y + 66), Vector2(width, 4)),
			float(w.get("stamina", 100)) / 100.0, UITheme.GOOD)
	UITheme.bar(self, Rect2(Vector2(x, r.position.y + 76), Vector2(width, 4)),
			float(w.get("mood", 70)) / 100.0, UITheme.WARN)


func _draw_detail(who: String) -> void:
	var w := _worker(who)
	var r := _panel_rect()
	var pw := r.size.x
	UITheme.panel(self, r, UITheme.BG, UITheme.worker_color(who))
	var x := r.position.x + 24
	UITheme.text_in(self, _font, Rect2(x, r.position.y + 20, pw - 48, 28), "%s · %s" % [UITheme.name_of(who), w.get("tag", "")],
			UITheme.TITLE, UITheme.worker_color(who))
	UITheme.portrait(self, who, Rect2(r.position + Vector2(pw - 76, 58), Vector2(52, 78)))
	var lines := UITheme.preview_lines(String(w.get("blurb", "")), int(pw - 126), _font, UITheme.SMALL, 2)
	for i in lines.size():
		UITheme.text_in(self, _font, Rect2(x, r.position.y + 54 + i * 22, pw - 126, 22), lines[i], UITheme.SMALL, UITheme.TEXT_DIM)

	# 复用状态条组件，保证和左下列表同一套刻度。
	# ★节点只在 _ready 建一次：_draw 里 new 一个再把旧的 free 掉，
	#   等于每帧建一次节点，redraw 频繁时会把场景树堆满。
	var sb := _sb
	sb.set_worker(w)
	sb.position = Vector2(x, r.position.y + 108)
	sb.size = Vector2(StatsBar.W, sb.total_height())

	var blurb := "手上没活"
	if w.get("job"):
		blurb = "正在服务一个客户"
	if w.get("brain_down", false):
		blurb = "脑袋宕机了 · 暂停接单和行动"
	UITheme.text_in(self, _font, Rect2(x, r.position.y + 220, pw - 48, 22), blurb, UITheme.SMALL,
			UITheme.BAD if w.get("brain_down", false) else UITheme.TEXT)
	var y := r.position.y + 250
	if w.get("brain_down", false):
		var checking := bool(w.get("brain_checking", false))
		_button(Rect2(x, y, pw - 48, 44), "正在检查恢复…" if checking else "额度恢复后 · 重启脑袋", "reboot", who, not checking)
		UITheme.text_in(self, _font, Rect2(x, y + 58, pw - 48, 22), "重启只检测一次，不会反复调用。", UITheme.SMALL, UITheme.TEXT_DIM)
		UITheme.text_in(self, _font, Rect2(x, r.end.y - 38, pw - 48, 22), "Esc 收起 · 其他员工仍可工作", UITheme.SMALL, UITheme.TEXT_FAINT)
		return
	_button(Rect2(x, y, pw - 48, 44), "与 %s 聊天" % UITheme.name_of(who), "chat", who)
	y += 52

	# 指令按钮
	var bw := (pw - 48.0 - 12.0) / 2.0
	# ★M4-4：加「今天轮休」。DESIGN 6.5 写着「玩家的应对：主动安排轮休」，
	#   原来面板上根本没有这个按钮——后端也没这条指令，整个疲劳系统是玩家够不到的。
	#   轮休是唯一能让疲劳降下来的操作（工作日必涨），没有它五个人必然集体罢工走光。
	# 直接读函数顶部那个 w（就是当前这个人的 worker 字典），不要在下面再 for 一遍
	# 找 selected —— 那个 w 已经在作用域里了，同名会让 GDScript 在**解析期**报
	# "There is already a variable named w"，等到运行都等不到。
	var off := bool(w.get("off_today", false))
	var defs := [
		["rest", "去休息", "lounge"], ["slack", "去摸鱼", "slack"],
		["meeting", "散会" if state.get("meeting") else "开会", null],
		["off", "恢复排班" if off else "今天轮休", null],
		["desk", "回工位", "desk"],
	]
	for i in range(defs.size()):
		var col := i % 2
		var row := i / 2
		var br := Rect2(x + col * (bw + 12.0), y + row * 40.0, bw, 36.0)
		var id := String(defs[i][0])
		_button(br, String(defs[i][1]), id, who)
	UITheme.text_in(self, _font, Rect2(x, r.end.y - 38, pw - 48, 22), "Esc 收起 · 点其他员工切换", UITheme.SMALL, UITheme.TEXT_FAINT)


func _button(r: Rect2, label: String, id: String, who: String, enabled := true) -> void:
	var hovered := _hover == "btn:" + id + ":" + who
	UITheme.button(self, r, hovered, enabled)
	UITheme.button_text(self, _font, r, label, UITheme.SMALL,
			UITheme.TEXT_FAINT if not enabled else (UITheme.ACCENT if hovered else UITheme.TEXT))
	if enabled:
		_btns.append({"id": id, "rect": r, "who": who})
	else:
		_disabled_btns.append({"rect":r, "reason":"正在检查额度恢复，请等待结果"})


func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseMotion:
		var h := ""
		for b in _utility_buttons:
			if b.rect.has_point(e.position):
				h = "utility:" + b.id
		for b in _btns:
			if b["rect"].has_point(e.position):
				h = "btn:%s:%s" % [b["id"], b["who"]]
		for b in _bars:
			if h.is_empty() and b["rect"].has_point(e.position):
				h = String(b["id"])
		for b in _chat_buttons:
			if b.rect.has_point(e.position):
				h = "chat:" + b.who
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if not h.is_empty() else Control.CURSOR_ARROW
		if h != _hover:
			_hover = h
			queue_redraw()
	elif e is InputEventMouseButton and e.pressed \
			and e.button_index == MOUSE_BUTTON_LEFT:
		for b in _disabled_btns:
			if b.rect.has_point(e.position):
				feedback.emit(b.reason)
				accept_event()
				return
		for b in _utility_buttons:
			if b.rect.has_point(e.position):
				utility_requested.emit(b.id)
				accept_event()
				return
		for b in _chat_buttons:
			if b.rect.has_point(e.position):
				chat_requested.emit(b.who)
				accept_event()
				return
		for b in _btns:
			if b["rect"].has_point(e.position):
				var who := String(b["who"])
				match String(b["id"]):
					"reboot":
						cmd_requested.emit(who, "reboot", null)
					"chat":
						chat_requested.emit(who)
					"meeting":
						cmd_requested.emit("", "dismiss" if state.get("meeting") else "meeting", null)
					"off":
						# 已轮休的人点这个是恢复排班，没轮休是让他今天歇
						# 面板的状态快照存在 state（不是 _data），轮休状态从里面读
						var cur := bool(_worker(who).get("off_today", false))
						cmd_requested.emit(who, "back" if cur else "off", null)
					"desk":
						cmd_requested.emit(who, "goto", "desk")
					_:
						cmd_requested.emit(who, "goto",
								"lounge" if b["id"] == "rest" else "slack")
				accept_event()
				return
		for b in _bars:
			if b["rect"].has_point(e.position):
				var who2 := String(b["id"]).replace("row:", "")
				if who2 != selected:
					selected = who2
					selection_changed.emit(selected)
				else:
					feedback.emit("已选中 %s · 点击卡片上的「聊天」即可对话" % UITheme.name_of(who2))
				queue_redraw()
				accept_event()
				return
		accept_event()


func _input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and (e as InputEventKey).keycode == KEY_ESCAPE \
			and not selected.is_empty():
		selected = ""
		selection_changed.emit(selected)
		queue_redraw()
		accept_event()
