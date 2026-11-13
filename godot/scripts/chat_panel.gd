class_name ChatPanel
extends Control
## 老板与单个 AI 的私聊面板（M2-7）
##
## 三条硬规则：
## 1. 200 字上限，前后端都挡。LineEdit.max_length 挡打字，但**粘贴能绕过**，
##    所以 can_send() 必须再判一次——这是后端那道 400 之前的第一道闸。
## 2. 回复必须逐片追加到同一个气泡，不能每来一个 delta 就 new 一个气泡，
##    否则屏幕上是刷出一排碎句而不是一句话在长出来。
## 3. 历史保留，面板关掉再打开不该丢。

signal send_requested(who, text)
signal closed()

const MAX_CHARS := 200

const COLORS := {
	"m3": "#7DC6FF", "flash": "#FFD166", "longcat": "#06D6A0",
	"kimi": "#B388FF", "step5": "#FF6B6B", "chief": "#7DC6FF", "boss": "#F2F5FA",
}
const NAMES := {
	"m3": "M3", "flash": "Flash", "longcat": "LongCat",
	"kimi": "Kimi", "step5": "Step5", "chief": "Chief", "boss": "你",
}

var who := ""
## 打回模式：面板不是聊天，而是收返工意见——这句话会真的发给 Chief。
var reject_request_id := ""
var reject_title := ""
## 这个工位上坐的是不是真实 Bot：是，每一句都会真的消耗一次模型调用。
var real_bot := false
var draft := ""
var bubbles: Array = []          # [{"who":String, "text":String, "done":bool}]
var streaming := false
var model_down := false

var _font: Font
var _entry: LineEdit
var _messages: ScrollContainer
var _bubble_canvas: Control
var _follow_tail := true
var _send_rect := Rect2()
var _close_rect := Rect2()


func _ready() -> void:
	_font = ThemeDB.fallback_font
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	_entry = LineEdit.new()
	_entry.max_length = MAX_CHARS
	_entry.placeholder_text = "跟他说点什么…"
	_entry.visible = false
	UITheme.style_input(_entry)
	_entry.text_changed.connect(_on_text_changed)
	_entry.text_submitted.connect(_on_submit)
	add_child(_entry)
	_messages = ScrollContainer.new()
	_messages.name = "ChatMessages"
	_messages.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_messages.clip_contents = true
	add_child(_messages)
	_bubble_canvas = Control.new()
	_bubble_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bubble_canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_bubble_canvas.draw.connect(_draw_transcript)
	_messages.add_child(_bubble_canvas)
	resized.connect(queue_redraw)


# ── 状态 ───────────────────────────────────────────────────────────────────
func open_with(id: String) -> void:
	# 换人不清空历史：老板是在跟不同的人各聊各的
	if who != id:
		streaming = false
	who = id
	reject_request_id = ""
	reject_title = ""
	set_model_down(false)
	visible = true
	_follow_tail = true
	draft = ""
	if _entry:
		_entry.text = ""
		_entry.visible = true
	queue_redraw()
	_entry.call_deferred("grab_focus")


## 打开打回面板：玩家写一句返工意见，这句话会真的交回 Chief。
func open_reject(request_id: String, title := "") -> void:
	streaming = false
	who = "chief"
	reject_request_id = request_id
	reject_title = title
	real_bot = false
	set_model_down(false)
	visible = true
	_follow_tail = true
	draft = ""
	if _entry:
		_entry.text = ""
		_entry.visible = true
	queue_redraw()
	_entry.call_deferred("grab_focus")


func close() -> void:
	var was_open := visible
	visible = false
	streaming = false
	if _entry:
		_entry.visible = false
	if was_open:
		closed.emit()


func set_draft(t: String) -> void:
	draft = t
	if _entry and _entry.text != t:
		_entry.text = t


func _on_text_changed(t: String) -> void:
	draft = t
	queue_redraw()


func over_limit() -> bool:
	return draft.length() > MAX_CHARS


func remaining() -> int:
	return MAX_CHARS - draft.length()


func can_send() -> bool:
	return not model_down and not streaming and not draft.strip_edges().is_empty() and not over_limit()


func set_model_down(down: bool) -> void:
	model_down = down
	if _entry:
		_entry.editable = not down
		if down:
			_entry.placeholder_text = "脑袋宕机了 · 恢复额度后重启"
		elif not reject_request_id.is_empty():
			_entry.placeholder_text = "写返工意见…"
		else:
			_entry.placeholder_text = "聊点什么？（最多 200 字）"
	queue_redraw()


## 切到真实 Bot 时打开：提示行要写明每发一句都消耗一次模型调用。
func set_real_bot(v: bool) -> void:
	real_bot = v
	queue_redraw()


func bubble_texts() -> Array:
	var out: Array = []
	for b in bubbles:
		out.append(b["text"])
	return out


# ── 流式 ───────────────────────────────────────────────────────────────────
func push_user(text: String) -> void:
	bubbles.append({"who": "boss", "text": text, "done": true, "conversation":who})
	_follow_tail = true
	queue_redraw()


func begin_stream() -> void:
	# ★ 一次流只起一个气泡。起完先放一条空的，
	#   后面所有 delta 都往这条上追加。
	bubbles.append({"who": who, "text": "", "done": false, "conversation":who})
	streaming = true
	_follow_tail = true
	queue_redraw()


func push_delta(text: String) -> void:
	if not streaming or bubbles.is_empty():
		begin_stream()
	bubbles[-1]["text"] += text
	_follow_tail = true
	queue_redraw()


func end_stream() -> void:
	if not bubbles.is_empty():
		bubbles[-1]["done"] = true
	streaming = false
	queue_redraw()


func _on_submit(t: String) -> void:
	var s := t.strip_edges()
	if not can_send() or who.is_empty():
		return
	push_user(s)
	set_draft("")
	send_requested.emit(who, s)


# ── 绘制 ───────────────────────────────────────────────────────────────────
func _draw() -> void:
	if not visible:
		return
	var vp := size
	draw_rect(Rect2(Vector2.ZERO, vp), Color(0.02, 0.03, 0.05, 0.66))

	var r := _panel_rect()
	var w := r.size.x
	UITheme.panel(self, r, UITheme.BG, UITheme.worker_color(who))

	UITheme.portrait(self, who, Rect2(r.position + Vector2(24, 22), Vector2(34, 42)))
	var nm: String = NAMES.get(who, who)
	var rejecting := not reject_request_id.is_empty()
	if rejecting:
		UITheme.text_in(self, _font, Rect2(r.position + Vector2(72, 20), Vector2(w - 216, 28)),
				"打回返工意见", UITheme.TITLE, Color(COLORS.get(who, "#fff")))
	else:
		UITheme.text_in(self, _font, Rect2(r.position + Vector2(72, 20), Vector2(w - 216, 28)),
				"与 %s 聊天" % nm, UITheme.TITLE, Color(COLORS.get(who, "#fff")))
	_close_rect = Rect2(r.end.x - 124, r.position.y + 20, 100, 34)
	UITheme.button(self, _close_rect, _close_rect.has_point(get_local_mouse_position()))
	UITheme.button_text(self, _font, _close_rect, "关闭 Esc", UITheme.SMALL, UITheme.TEXT)
	var hint := "随时和员工聊聊，也可以聊工作以外的话题"
	if rejecting:
		hint = "这句话会真的发给 Chief，由它重新派单（会消耗一次模型调用）"
	elif real_bot:
		hint = "在跟真实的 Bot 说话 · 每发一句都会消耗一次模型调用"
	UITheme.text_in(self, _font, Rect2(r.position + Vector2(24, 58), Vector2(w - 48, 22)), hint, UITheme.SMALL, UITheme.TEXT_DIM)

	_draw_bubbles(r)
	_draw_input(r)


func _draw_bubbles(r: Rect2) -> void:
	_messages.position = r.position + Vector2(24, 94)
	_messages.size = Vector2(r.size.x - 48, r.size.y - 224)
	var height := 0.0
	for bubble in _message_layout():
		height += bubble.height + 10
	_bubble_canvas.custom_minimum_size = Vector2(0, maxf(0, height - 10))
	_bubble_canvas.queue_redraw()
	if _follow_tail:
		_follow_tail = false
		call_deferred("_scroll_to_bottom")


func _message_layout() -> Array:
	var layout: Array = []
	var width := maxf(120, _messages.size.x - 12)
	for i in bubbles.size():
		var bubble: Dictionary = bubbles[i]
		if str(bubble.get("conversation", "")) != who:
			continue
		var txt := str(bubble.text) + ("▍" if streaming and i == bubbles.size() - 1 else "")
		var lines := UITheme.wrap(txt, int(width - 104), _font, UITheme.BODY)
		layout.append({"who":str(bubble.who), "lines":lines, "width":width, "height":maxi(1, lines.size()) * 26 + 28})
	return layout


func _draw_transcript() -> void:
	var y := 0.0
	for bubble in _message_layout():
		UITheme.patch(_bubble_canvas, Rect2(0, y, bubble.width, bubble.height), "dialogue_bubble", .18)
		UITheme.text_in(_bubble_canvas, _font, Rect2(14, y + 14, 64, 24), NAMES.get(bubble.who, bubble.who), UITheme.SMALL, Color("#734522"))
		for i in bubble.lines.size():
			UITheme.text_in(_bubble_canvas, _font, Rect2(90, y + 14 + i * 26, bubble.width - 104, 26), bubble.lines[i], UITheme.BODY, Color("#463022"))
		y += bubble.height + 10


func _scroll_to_bottom() -> void:
	await get_tree().process_frame
	if is_instance_valid(_messages):
		_messages.scroll_vertical = int(_messages.get_v_scroll_bar().max_value)


func _panel_rect() -> Rect2:
	var width := minf(620, size.x - 48)
	var height := minf(560, size.y - 96)
	return Rect2((size.x - width) * .5, (size.y - height) * .5, width, height)


func _draw_input(r: Rect2) -> void:
	var box := Rect2(r.position.x + 24, r.end.y - 110, r.size.x - 160, 44)
	draw_rect(box, Color("#261816"))
	draw_rect(box, Color("#ff6b6b") if over_limit() else Color("#d4a558"), false, 1.0)
	if _entry and _entry.visible:
		_entry.position = box.position + Vector2(10, 8)
		_entry.size = Vector2(box.size.x - 20, 28)
	_send_rect = Rect2(r.end.x - 124, box.position.y, 100, 44)
	UITheme.button(self, _send_rect, _send_rect.has_point(get_local_mouse_position()), can_send())
	UITheme.button_text(self, _font, _send_rect, "回复中…" if streaming else "发送", UITheme.BODY, UITheme.TEXT if can_send() else UITheme.TEXT_FAINT)
	# 计数：超了要变红，让玩家自己看出为什么发不出去
	var rem := remaining()
	var cc := Color("#ff6b6b") if over_limit() else Color("#b5a587")
	UITheme.text_in(self, _font, Rect2(r.position.x + 24, r.end.y - 48, 140, 22),
			"%d / %d 字" % [draft.length(), MAX_CHARS], UITheme.SMALL, cc)
	var can := can_send()
	UITheme.text_in(self, _font, Rect2(r.end.x - 304, r.end.y - 48, 280, 22),
			"脑袋宕机了" if model_down else ("回车或点击发送" if can else ("等员工回复…" if streaming else "输入消息后发送")), UITheme.SMALL,
			UITheme.BAD if model_down else (Color("#06D6A0") if can else Color("#937e62")), HORIZONTAL_ALIGNMENT_RIGHT)


func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseMotion:
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if _close_rect.has_point(e.position) or (_send_rect.has_point(e.position) and can_send()) else Control.CURSOR_ARROW
		queue_redraw()
	elif e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
		if _close_rect.has_point(e.position):
			close()
		elif _send_rect.has_point(e.position) and can_send():
			_on_submit(draft)
		accept_event()


func _input(e: InputEvent) -> void:
	if visible and e is InputEventKey and e.pressed and e.keycode == KEY_ESCAPE:
		close()
		accept_event()
