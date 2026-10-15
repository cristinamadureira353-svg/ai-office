class_name BlameUI
extends Control
## 甩锅复盘会界面（M2-6）
## 一单砸了，五个人开会互相推责任。老板可以在会上插话（回车发言）。
##
## 台词是模型现场生成的，这里只负责把 transcript 排开给人看：
## 谁说了什么、被点名的是谁、最后谁背了锅。

signal talk_sent(text)

const COLORS := {
	"m3": "#7DC6FF", "flash": "#FFD166", "longcat": "#06D6A0",
	"kimi": "#B388FF", "step5": "#FF6B6B",
	"boss": "#F2F5FA",
}
const NAMES := {
	"m3": "M3", "flash": "Flash", "longcat": "LongCat",
	"kimi": "Kimi", "step5": "Step5", "boss": "你",
}

const PANEL := Vector2(720.0, 500.0)
const MAX_SHOWN := 5
const LINE_H := 52.0

var mt: Dictionary = {}
var _font: Font
var _input: LineEdit
var details_open := false


func _ready() -> void:
	_font = ThemeDB.fallback_font
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	_input = LineEdit.new()
	_input.max_length = 80
	_input.placeholder_text = "在复盘会上插一句…（回车发言）"
	_input.visible = false
	UITheme.style_input(_input)
	_input.text_submitted.connect(_on_submit)
	add_child(_input)


func show_meeting(data: Dictionary) -> void:
	mt = data
	visible = true
	_input.visible = data.get("kind", "") == "blame" \
			and data.get("phase", "") == "talking"
	queue_redraw()


func hide_meeting() -> void:
	mt = {}
	visible = false
	_input.visible = false
	queue_redraw()


func _on_submit(t: String) -> void:
	var s := t.strip_edges()
	if s.is_empty():
		return
	_input.text = ""
	talk_sent.emit(s)


func _panel_rect() -> Rect2:
	return Rect2((size.x - PANEL.x) / 2.0, (size.y - PANEL.y) / 2.0, PANEL.x, PANEL.y)


func _brief_rect() -> Rect2:
	var preferred_y := GameHUD.EVENT_Y if size.y < 850 else GameHUD.EVENT_Y + GameHUD.EVENT_H + 16
	var brief_y := minf(preferred_y, size.y - 172 - 16 - 144)
	return Rect2(size.x - 272, brief_y, 258, 144)


func _draw() -> void:
	if mt.is_empty():
		return
	if mt.get("kind", "normal") != "blame":
		if details_open:
			return
		var brief := _brief_rect()
		UITheme.panel(self, brief)
		var title := UITheme.preview_lines(str(mt.get("topic", "周会")), 210, _font, 14, 2)
		for i in title.size():
			UITheme.text_in(self, _font, Rect2(brief.position + Vector2(24, 24 + i * 20), Vector2(210, 20)), title[i], 14, UITheme.WARN)
		UITheme.text_in(self, _font, Rect2(brief.position + Vector2(24, 76), Vector2(210, 18)), "就座 %d / 5 · %s" % [mt.get("seated", []).size(), _phase_text()], 12, UITheme.TEXT)
		UITheme.text_in(self, _font, Rect2(brief.position + Vector2(24, 102), Vector2(210, 18)), "点员工卡 → 散会", 12, UITheme.TEXT_DIM)
		return
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.02, 0.03, 0.05, 0.74))

	var r := _panel_rect()
	UITheme.panel(self, r, UITheme.BG, UITheme.BAD)

	UITheme.text_in(self, _font, Rect2(r.position + Vector2(24, 24), Vector2(80, 24)), "复盘会", 15, UITheme.BAD)
	UITheme.text_in(self, _font, Rect2(r.position + Vector2(120, 24), Vector2(PANEL.x - 144, 24)), _phase_text(), 12, UITheme.TEXT_DIM)

	var lines: Array = mt.get("lines", [])
	if lines.size() > MAX_SHOWN:
		lines = lines.slice(lines.size() - MAX_SHOWN)
	var y := r.position.y + 88.0
	if lines.is_empty():
		_text(Vector2(r.position.x + 22, y + 12), _waiting_text(), 13, Color("#ffd166"))
	else:
		for ln in lines:
			var who: String = str(ln.get("who", ""))
			var nm: String = NAMES.get(who, who)
			var col: Color = Color(COLORS.get(who, "#888"))
			UITheme.text_in(self, _font, Rect2(r.position.x + 24, y, 64, 20), nm, 12, col)
			var txt := str(ln.get("text", ""))
			# 命中即高亮，能一眼看出"这局在推谁"
			var hit := _highlight(ln)
			var wrapped := UITheme.preview_lines(txt, int(PANEL.x - 128), _font, 12, 2)
			for i in wrapped.size():
				UITheme.text_in(self, _font, Rect2(r.position.x + 104, y + i * 20, PANEL.x - 128, 20), wrapped[i], 12, hit)
			y += LINE_H

	_draw_settled(r, y)

	# 插话框只在"还在说"的时候给
	if _input.visible:
		var box := Rect2(r.position.x + 24, r.end.y - 60, PANEL.x - 48, 36)
		draw_rect(box, Color("#261816"))
		draw_rect(box, Color("#d4a558"), false, 1.0)
		_input.position = box.position + Vector2(10, 6)
		_input.size = Vector2(box.size.x - 20, 24)


func _highlight(ln: Dictionary) -> Color:
	var bl: Array = ln.get("blames", [])
	if not bl.is_empty():
		return Color("#ff9f6b")       # 点名了别人 = 甩锅
	if str(ln.get("who", "")) == "boss":
		return Color("#F2F5FA")
	return Color("#f4e6c7")


func _phase_text() -> String:
	match str(mt.get("phase", "")):
		"gathering": return "大家正在往会议室走…"
		"seated": return "会议进行中" if mt.get("kind", "normal") == "normal" else "都已就座，即将开始"
		"talking": return "正在发言，你可以插话"
		"settled": return "已结束"
	return str(mt.get("topic", ""))


func _waiting_text() -> String:
	if str(mt.get("kind", "")) != "blame":
		return "会议进行中…"
	return "还在酝酿怎么开口…"


func _draw_settled(r: Rect2, y: float) -> void:
	var s: Dictionary = mt.get("settled", {}) if mt.get("settled") else {}
	if s.is_empty():
		return
	var culprit := str(s.get("culprit", "") if s.get("culprit") else "")
	var msg := "没人被点名，这锅没着落"
	var col := Color("#b5a587")
	if culprit != "":
		msg = "%s 被推出来背锅，心情 -6" % NAMES.get(culprit, culprit)
		col = Color("#ff6b6b")
	UITheme.text_in(self, _font, Rect2(r.position.x + 24, y + 8, PANEL.x - 48, 22), msg, 13, col)


func _text(pos: Vector2, s: String, fs: int, col: Color) -> void:
	draw_string(_font, pos, s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
