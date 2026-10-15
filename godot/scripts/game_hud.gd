class_name GameHUD
extends Control
## M1-5 客户端 UI：顶栏 + 客户面板 + 派单 + 验收 + 事件流。
## 防线3（客户端侧）：任何超长文本在显示前截断，UI 永不被撑爆。

const CLIENT_FONT_SIZE := UITheme.BODY
const C_PANEL := Color("#35201e")
const C_LINE := Color("#97572d")
const C_TXT := Color("#f4e6c7")
const C_DIM := UITheme.TEXT_DIM
const C_GOLD := Color("#ffd166")
const C_GREEN := Color("#06d6a0")
const C_RED := Color("#ff6b6b")

var link: BackendLink
var state: Dictionary = {}
var _font: Font
var _client_rows: Array = []
var details_open := false
var day_button := Rect2(700, 20, 144, 36)
const CLIENT_Y := 84.0
const CLIENT_H := 356.0
const EVENT_Y := 456.0
const EVENT_H := 216.0
## M3-8：HUD 换上 M3-6 的正式图标
const ICON_DIR := "res://assets/cozy_office/resources/ui/"
var _icons: Dictionary = {}


func icon(nm: String) -> Texture2D:
	if _icons.has(nm):
		return _icons[nm]
	var p := ICON_DIR + "icon_" + ("reputation" if nm == "rep" else nm) + ".tres"
	var t: Texture2D = null
	if ResourceLoader.exists(p):
		t = load(p)
	_icons[nm] = t
	return t


func _icon_at(nm: String, pos: Vector2, col: Color) -> float:
	"""画一个图标，返回它占的宽度；没有素材就返回 0（文字自动贴上来）。"""
	var t := icon(nm)
	if t == null:
		return 0.0
	draw_texture_rect(t, Rect2(pos, Vector2(18, 18)), false)
	return 23.0
var _toast_text := ""
var _toast_until := 0.0
var _shown_error_count := -1


func _ready() -> void:
	_font = ThemeDB.fallback_font
	# Control 在 CanvasLayer 里必须显式铺满，否则 size 拿到 0，面板会画到屏幕外
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(queue_redraw)
	if link == null:
		link = BackendLink.new()
		link.interval = 0.4
		add_child(link)
	link.state_updated.connect(_on_state)
	link.connection_changed.connect(_on_conn)
	set_process(true)


func _on_conn(c: bool) -> void:
	toast("已连接后端" if c else "⚠ 连接断开（后端没在跑？）")


func _on_state(d: Dictionary) -> void:
	state = d
	queue_redraw()


func toast(t: String) -> void:
	_toast_text = t
	_toast_until = Time.get_ticks_msec() + 2200
	queue_redraw()

func client_at(screen: Vector2) -> String:
	for row in _client_rows:
		if row.rect.has_point(screen):
			return row.id
	return ""


## ★ 防线3：客户端截断
static func cut(s: String, limit: int = P_DISPLAY_LIMIT) -> String:
	var t := (s if s != null else "").strip_edges()
	if t.length() <= limit:
		return t
	return t.substr(0, limit) + "（他话太多了）"


const P_DISPLAY_LIMIT := 200


func _process(_d: float) -> void:
	if state.is_empty() and link and _shown_error_count != link.error_count:
		_shown_error_count = link.error_count
		queue_redraw()
	if not _toast_text.is_empty() and Time.get_ticks_msec() > _toast_until:
		_toast_text = ""
		queue_redraw()


func _draw() -> void:
	if state.is_empty():
		_panel(Rect2(12, 10, size.x - 24, 56))
		UITheme.text_in(self, _font, Rect2(32, 24, 112, 28), "AI 事务所", UITheme.TITLE, C_TXT)
		var message := "正在读取游戏进度…"
		if link and link.error_count > 0:
			message = "游戏状态读取失败，正在重试。可尝试重新打开游戏。"
		UITheme.text_in(self, _font, Rect2(158, 24, size.x - 190, 28), message, UITheme.BODY, C_GOLD)
		return
	_draw_top()
	_draw_clients()
	_draw_events()
	if not _toast_text.is_empty():
		_draw_toast()


func _panel(r: Rect2) -> void:
	UITheme.panel(self, r)


func _draw_top() -> void:
	var vp := size
	_panel(Rect2(12, 10, vp.x - 24, 56))
	UITheme.text_in(self, _font, Rect2(32, 24, 112, 28), "AI 事务所", UITheme.TITLE, C_TXT)
	var wx := 158.0 + _icon_at("time", Vector2(158, 29), Color("#7DC6FF"))
	UITheme.text_in(self, _font, Rect2(wx, 26, 86, 24), "第 %d 天" % int(state.get("day", 1)), UITheme.BODY, Color("#7DC6FF"))
	UITheme.text_in(self, _font, Rect2(276, 26, 66, 24), String(state.get("clock", "--:--")), UITheme.BODY, C_DIM)
	var mx := 356.0 + _icon_at("money", Vector2(356, 29), C_GOLD)
	UITheme.text_in(self, _font, Rect2(mx, 26, 148, 24), "资金 %d" % int(state.get("money", 0)), UITheme.BODY, C_GOLD)
	var rx := 536.0 + _icon_at("rep", Vector2(536, 29), C_GREEN)
	UITheme.text_in(self, _font, Rect2(rx, 26, 136, 24), "声誉 %d" % int(state.get("rep", 0)), UITheme.BODY, C_GREEN)
	UITheme.button(self, day_button, day_button.has_point(get_local_mouse_position()))
	UITheme.button_text(self, _font, day_button, "N · 结束当天", UITheme.SMALL, C_TXT)
	var online := "● 在线" if (link != null and link.connected) else "○ 离线"
	UITheme.text_in(self, _font, Rect2(vp.x - 128, 26, 96, 24), online, UITheme.SMALL,
			C_GREEN if (link != null and link.connected) else C_RED)


func _draw_clients() -> void:
	_client_rows.clear()
	if details_open:
		return
	var vp := size
	var x := vp.x - 356.0
	var y := CLIENT_Y
	var w := 340.0
	var h := CLIENT_H
	_panel(Rect2(x, y, w, h))
	UITheme.text_in(self, _font, Rect2(x + 24, y + 20, w - 48, 28), "客户队列 · 点击派单", UITheme.TITLE, C_TXT)

	var cs: Array = state.get("clients", [])
	var waiting := cs.filter(func(c): return c.get("status") in ["等待", "抢单中", "服务中", "待验收"])
	if waiting.is_empty():
		UITheme.text_in(self, _font, Rect2(x + 24, y + 62, w - 48, 24), "暂无客户，等一会儿…", UITheme.BODY, C_DIM)
		return

	var i := 0
	for c in waiting:
		if i >= 5:
			break
		var cy := y + 60 + i * 54
		var st := String(c.get("status", ""))
		var col := C_GREEN if st == "待验收" else (C_GOLD if st == "等待" else Color("#7DC6FF"))
		var tag := "[" + st + "]"
		UITheme.text_in(self, _font, Rect2(x + 24, cy, 76, 24), tag, UITheme.SMALL, col)
		UITheme.text_in(self, _font, Rect2(x + 110, cy, 118, 24), String(c.get("task", "")), UITheme.BODY, C_TXT)
		_client_rows.append({"id": str(c.get("id", "")), "rect": Rect2(x + 16, cy, w - 32, 48)})
		UITheme.text_in(self, _font, Rect2(x + 236, cy, w - 260, 24), "%d元" % int(c.get("reward", 0)), UITheme.SMALL, C_GOLD, HORIZONTAL_ALIGNMENT_RIGHT)
		# 耐心条
		var pm := float(c.get("patience_max", 1))
		var p := float(c.get("patience", 0)) / maxf(1.0, pm)
		UITheme.bar(self, Rect2(x + 24, cy + 33, 80, 4), p, C_RED if p < .3 else C_GREEN)
		# 注意用 = 而不是 :=：c.get() 返回 Variant，:= 无法推断类型会编译失败
		var served = c.get("served_by")
		if served != null and String(served) != "":
			UITheme.text_in(self, _font, Rect2(x + 114, cy + 26, w - 138, 22), "经办：%s" % UITheme.name_of(String(served)), UITheme.SMALL, C_DIM)
		i += 1


func _draw_events() -> void:
	if details_open or (size.y < 850 and not UITheme.dict_of(state, "meeting").is_empty()):
		return
	var vp := size
	var x := vp.x - 356.0
	var y := EVENT_Y
	var w := 340.0
	var h := minf(EVENT_H, size.y - 188 - y)
	if h < 116:
		return
	_panel(Rect2(x, y, w, h))
	UITheme.text_in(self, _font, Rect2(x + 24, y + 20, w - 48, 28), "最近事件", UITheme.TITLE, C_TXT)
	var evs: Array = state.get("events", [])
	var n := mini(evs.size(), int((h - 80) / 24))
	for i in n:
		var e: Dictionary = evs[evs.size() - 1 - i]
		UITheme.text_in(self, _font, Rect2(x + 24, y + 56 + i * 24, w - 48, 24), String(e.get("text", "")), UITheme.SMALL, C_DIM)


func _draw_toast() -> void:
	var vp := size
	var width := minf(vp.x - 432, maxf(360, _font.get_string_size(_toast_text, HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.BODY).x + 48))
	var lines := UITheme.preview_lines(_toast_text, int(width - 48), _font, UITheme.BODY, 3)
	var r := Rect2((vp.x - 416 - width) * .5, 76, width, maxf(1, lines.size()) * 26 + 48)
	UITheme.panel(self, r)
	for i in lines.size():
		UITheme.text_in(self, _font, Rect2(r.position + Vector2(24, 24 + i * 26), Vector2(width - 48, 26)), lines[i], UITheme.BODY, C_TXT)
