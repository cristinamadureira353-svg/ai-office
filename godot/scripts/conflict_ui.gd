class_name ConflictUI
extends Control
## 抢单冲突裁决界面（M2-4）
## 两个 AI 当面对线，玩家决定这活给谁。台词是模型现场生成的。

signal judge_pressed(client_id, kind)

const COLORS := {
	"m3": "#7DC6FF", "flash": "#FFD166", "longcat": "#06D6A0",
	"kimi": "#B388FF", "step5": "#FF6B6B",
}
const NAMES := {
	"m3": "M3", "flash": "Flash", "longcat": "LongCat",
	"kimi": "Kimi", "step5": "Step5",
}

var cf: Dictionary = {}
var _font: Font
var _buttons: Array = []
var submitting := false
var _message := ""
var _message_color := UITheme.TEXT_DIM


func _ready() -> void:
	_font = ThemeDB.fallback_font
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false


func show_conflict(data: Dictionary) -> void:
	if str(data.get("client", "")) != str(cf.get("client", "")):
		submitting = false
		_message = ""
	cf = data
	visible = true
	queue_redraw()


func hide_conflict() -> void:
	cf = {}
	submitting = false
	_message = ""
	_buttons.clear()
	visible = false
	queue_redraw()


func complete_judgement(client_id: String, ok: bool, msg: String) -> void:
	if not visible or str(cf.get("client", "")) != client_id:
		return
	submitting = ok
	_message = "裁决已完成，正在更新…" if ok else msg
	_message_color = UITheme.GOOD if ok else UITheme.BAD
	queue_redraw()


func _process(_d: float) -> void:
	if not visible and not cf.is_empty():
		hide_conflict()


func _draw() -> void:
	if cf.is_empty():
		return
	var vp := size
	# 压暗背景
	draw_rect(Rect2(Vector2.ZERO, vp), Color(0.02, 0.03, 0.05, 0.72))

	var w := 620.0
	var h := 390.0
	var r := Rect2((vp.x - w) / 2.0, (vp.y - h) / 2.0, w, h)
	UITheme.panel(self, r, UITheme.BG, UITheme.BAD)

	var a: String = cf.get("a", "")
	var b: String = cf.get("b", "")
	var task := str(cf.get("task", ""))
	UITheme.text_in(self, _font, Rect2(r.position + Vector2(24, 24), Vector2(w - 48, 24)), "抢单冲突", 15, UITheme.BAD)
	UITheme.text_in(self, _font, Rect2(r.position + Vector2(24, 56), Vector2(w - 48, 20)), "「%s」这单，归谁？" % task, 12, UITheme.TEXT_DIM)

	var lines: Array = cf.get("lines", [])
	var y := r.position.y + 92.0
	lines = lines.slice(maxi(0, lines.size() - 4))
	if lines.is_empty():
		UITheme.text_in(self, _font, Rect2(r.position.x + 24, y, w - 48, 20), "请选择接单员工，或结束这次冲突。", 13, UITheme.WARN)
	else:
		for ln in lines:
			var who: String = ln.get("who", "")
			var nm: String = NAMES.get(who, who)
			var col: Color = Color(COLORS.get(who, "#888"))
			UITheme.text_in(self, _font, Rect2(r.position.x + 24, y, 64, 20), nm, 12, col)
			var txt: String = str(ln.get("text", ""))
			var wrapped := UITheme.preview_lines(txt, int(w - 124), _font, 12, 2)
			for i in wrapped.size():
				UITheme.text_in(self, _font, Rect2(r.position.x + 100, y + i * 20, w - 124, 20), wrapped[i], 12, UITheme.TEXT)
			y += 52.0

	# 裁决按钮
	if not _message.is_empty():
		UITheme.text_in(self, _font, Rect2(r.position.x + 24, r.end.y - 88, w - 48, 20), _message, UITheme.SMALL, _message_color)
	_buttons.clear()
	var by := r.end.y - 60
	var bw := (w - 48 - 30) / 4
	var labels := ["让 %s" % NAMES.get(a, a), "让 %s" % NAMES.get(b, b), "都不接", "骂两句"]
	for i in 4:
		var button := Rect2(r.position.x + 24 + i * (bw + 10), by, bw, 36)
		_button(button, labels[i], UITheme.TEXT)
		_buttons.append({"rect":button, "kind":["a", "b", "reject", "scold"][i]})


func _button(r: Rect2, label: String, col: Color) -> void:
	UITheme.button(self, r, not submitting and r.has_point(get_local_mouse_position()), not submitting)
	UITheme.button_text(self, _font, r, label, 12, UITheme.TEXT_FAINT if submitting else col)


func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseMotion:
		queue_redraw()
	if visible and e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
		if submitting:
			accept_event()
			return
		for button in _buttons:
			if button.rect.has_point(e.position):
				submitting = true
				_message = "正在提交裁决…"
				_message_color = UITheme.TEXT_DIM
				accept_event()
				queue_redraw()
				judge_pressed.emit(str(cf.get("client", "")), button.kind)
				return
