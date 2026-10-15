class_name ClientPanel
extends Control
## 客户信息面板（DESIGN 9.2「点客户」）
## 需求详情 + 派谁去 + 验收/打回。带玩家手输的空间（自由打字不限制）。

signal cmd_requested(who, action, arg)
signal accept_requested(client_id, approved)
signal feedback(message)

const W := 380.0
const H := 468.0

var client: Dictionary = {}
var workers: Array = []
var _font: Font
var _btns: Array = []
var _hover := ""
var _result: RichTextLabel
var _disabled_btns: Array = []
var _close_rect := Rect2()


func _ready() -> void:
	_font = ThemeDB.fallback_font
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_PASS
	visible = false
	_result = RichTextLabel.new()
	_result.name = "ClientBody"
	_result.add_theme_font_override("normal_font", ThemeDB.fallback_font)
	_result.scroll_active = true
	_result.clip_contents = true
	_result.add_theme_font_size_override("normal_font_size", UITheme.BODY)
	_result.add_theme_color_override("default_color", UITheme.TEXT)
	_result.add_theme_constant_override("line_separation", 4)
	add_child(_result)
	resized.connect(queue_redraw)
	mouse_exited.connect(func():
		_hover = ""
		tooltip_text = ""
		queue_redraw())


func show_client(c: Dictionary, ws: Array) -> void:
	var changed_client := str(client.get("id", "")) != str(c.get("id", ""))
	client = c
	workers = ws
	visible = not c.is_empty()
	if changed_client and _result:
		_result.get_v_scroll_bar().value = 0
	queue_redraw()


func _draw() -> void:
	_btns.clear()
	_disabled_btns.clear()
	if client.is_empty():
		return
	var r := _panel_rect()
	UITheme.panel(self, r)
	var x := r.position.x + UITheme.PAD
	var width := r.size.x - UITheme.PAD * 2
	var st := String(client.get("status", ""))
	var scol := UITheme.TEXT_DIM
	if st == "待验收":
		scol = UITheme.WARN
	elif st in ["已流失", "已放弃"]:
		scol = UITheme.BAD
	UITheme.text_in(self, _font, Rect2(x, r.position.y + 20, width - 70, 28), "客户 · " + st, UITheme.TITLE, UITheme.ACCENT)
	_close_rect = Rect2(r.end.x - 82, r.position.y + 18, 58, 32)
	UITheme.button(self, _close_rect, _hover == "close")
	UITheme.button_text(self, _font, _close_rect, "关闭", UITheme.SMALL, UITheme.TEXT)
	UITheme.text_in(self, _font, Rect2(x, r.position.y + 54, width, 24), "酬金：%d 元" % int(client.get("reward", 0)), UITheme.BODY, scol)
	var pmax := float(client.get("patience_max", 1))
	UITheme.text_in(self, _font, Rect2(x, r.position.y + 82, 40, 22), "耐心", UITheme.SMALL, UITheme.TEXT_DIM)
	UITheme.bar(self, Rect2(Vector2(x + 52, r.position.y + 90), Vector2(width - 52, 5)),
			float(client.get("patience", 0)) / maxf(1.0, pmax), UITheme.GOOD)
	var button_height := 40.0
	var y := r.end.y - 24 - 22 - 12 - (40 if st == "待验收" else 88)
	_result.position = Vector2(x, r.position.y + 120)
	_result.size = Vector2(width, y - 16 - _result.position.y)
	var text := "需求：\n" + str(client.get("task", ""))
	if st == "待验收":
		var res := String(client.get("result", ""))
		text += "\n\n交付物：\n" + (res if not res.is_empty() else "（他什么也没交）")
		var bw := (width - 12) * .5
		_button(Rect2(x, y, bw, button_height), "验收通过", "ok", "")
		_button(Rect2(x + bw + 12, y, bw, button_height), "打回", "no", "")
	else:
		var bw := (width - 20) / 3
		for i in range(mini(5, workers.size())):
			var w: Dictionary = workers[i]
			var who := String(w.get("id", ""))
			var reason := _unavailable_reason(w)
			var br := Rect2(x + (i % 3) * (bw + 10), y + (i / 3) * 48, bw, button_height)
			_button(br, UITheme.name_of(who), "assign:" + who, who, reason.is_empty(), reason)
	if _result.text != text:
		_result.text = text
	UITheme.text_in(self, _font, Rect2(x, r.end.y - 40, width, 22),
			"正文可滚动 · Esc 关闭" if st == "待验收" else (
				"派谁去接 · 灰色按钮可查看原因" if st == "等待" else "员工正在处理 · 完成后验收"), UITheme.SMALL, UITheme.TEXT_DIM)


func _panel_rect() -> Rect2:
	return Rect2(size.x - W - 16, 76, W, H)


func _has_point(point: Vector2) -> bool:
	return _panel_rect().has_point(point)


func _unavailable_reason(w: Dictionary) -> String:
	var name := UITheme.name_of(str(w.get("id", "")))
	if str(client.get("status", "等待")) != "等待":
		var owner := UITheme.str_of(client, "served_by")
		return "该单正在由 %s 处理，完成后可验收" % UITheme.name_of(owner) if not owner.is_empty() else "该单正在处理中，暂时不能重新派单"
	if w.get("brain_down", false):
		return name + " 脑袋宕机了，恢复额度后在员工详情重启脑袋"
	if w.get("quit", false):
		return name + " 已离职，无法接单"
	if w.get("strike", false):
		return name + " 正在罢工，无法接单"
	if w.get("off_today", false):
		return name + " 今天轮休，可在员工详情恢复排班"
	if float(w.get("stamina", 100)) < 15:
		return name + " 体力不足，先安排休息"
	if not UITheme.str_of(w, "job").is_empty():
		return name + " 正在处理另一单，完成后才能接新单"
	return ""


func _button(r: Rect2, label: String, id: String, who: String, enabled := true, reason := "") -> void:
	var key := id + ":" + who
	var hovered := _hover == key and enabled
	var base := UITheme.ACCENT if enabled else UITheme.TEXT_FAINT
	UITheme.button(self, r, hovered, enabled)
	UITheme.button_text(self, _font, r, label, UITheme.SMALL,
			base if enabled else UITheme.TEXT_FAINT)
	if enabled:
		_btns.append({"id": id, "rect": r, "who": who})
	else:
		_disabled_btns.append({"rect":r, "reason":reason})


func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseMotion:
		var h := ""
		tooltip_text = ""
		if _close_rect.has_point(e.position):
			h = "close"
		for b in _btns:
			if b["rect"].has_point(e.position):
				h = String(b["id"]) + ":" + String(b["who"])
		for b in _disabled_btns:
			if b.rect.has_point(e.position):
				tooltip_text = b.reason
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if not h.is_empty() else (Control.CURSOR_HELP if not tooltip_text.is_empty() else Control.CURSOR_ARROW)
		if h != _hover:
			_hover = h
			queue_redraw()
	elif e is InputEventMouseButton and e.pressed \
			and e.button_index == MOUSE_BUTTON_LEFT:
		if _close_rect.has_point(e.position):
			show_client({}, workers)
			accept_event()
			return
		for b in _disabled_btns:
			if b.rect.has_point(e.position):
				feedback.emit(b.reason)
				accept_event()
				return
		for b in _btns:
			if b["rect"].has_point(e.position):
				var id := String(b["id"])
				if id == "ok":
					accept_requested.emit(String(client.get("id", "")), true)
				elif id == "no":
					accept_requested.emit(String(client.get("id", "")), false)
				elif id.begins_with("assign:"):
					cmd_requested.emit(id.replace("assign:", ""), "assign",
							String(client.get("id", "")))
				accept_event()
				return
		accept_event()


func _input(e: InputEvent) -> void:
	if visible and e is InputEventKey and e.pressed and (e as InputEventKey).keycode == KEY_ESCAPE:
		show_client({}, workers)
		accept_event()
