class_name GameHUD
extends Control
## M1-5 客户端 UI：顶栏 + 真任务看板 + 事件流。
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
## 待办列表的滚动窗口：_task_rect 是列表区域，_task_total/_task_rows 供滚动夹取用。
var _task_rect := Rect2()
var _task_scroll := 0
var _task_total := 0
var _task_rows := 1
## 看板上的「打回」按钮：点了就把返工意见交回 Chief。
var _reject_rects: Array = []
var details_open := false
var day_button := Rect2(700, 20, 144, 36)
## 真实任务看板里的「对 Chief 说…」按钮；没有 Bot 面板时保持空矩形。
var bot_button := Rect2()
## 按钮必须由 GUI 吃掉点击，否则点击穿透到世界里，Godot 不会建立控件焦点，
## 随后打开的聊天输入框就收不到键盘。
signal chief_requested
var _chief_area: Control
const CLIENT_Y := 84.0
const CLIENT_H := 356.0
## 待办列表：一行多高、从面板顶往下留多少、底部留多少。
## 能放几行由面板高度算出来，不写死——面板变高就会自动多显示几条。
const TASK_ROW_H := 54.0
const TASK_LIST_TOP := 60.0
const TASK_LIST_PAD := 20.0
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
	_chief_area = Control.new()
	_chief_area.name = "ChiefButtonArea"
	_chief_area.mouse_filter = Control.MOUSE_FILTER_STOP
	_chief_area.visible = false
	_chief_area.gui_input.connect(_on_chief_area_input)
	add_child(_chief_area)
	set_process(true)


func _on_chief_area_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_chief_area.accept_event()
		chief_requested.emit()


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
	_draw_bot_board()
	if not _toast_text.is_empty():
		_draw_toast()


func _panel(r: Rect2) -> void:
	UITheme.panel(self, r)


## 大数字的易读写法：1.2M / 38.5K / 912。顶栏 token 一栏用它，别在手写。
static func short_num(n: int) -> String:
	if n >= 1000000:
		return "%.1fM" % (n / 1000000.0)
	if n >= 1000:
		return "%.1fK" % (n / 1000.0)
	return str(n)


func _draw_top() -> void:
	var vp := size
	_panel(Rect2(12, 10, vp.x - 24, 56))
	UITheme.text_in(self, _font, Rect2(32, 24, 112, 28), "AI 事务所", UITheme.TITLE, C_TXT)
	# 顶栏换成真统计：今天日期 + Bot 团队的在线/今日完成/今日 token。
	# 数字来自 /api/office/panel 的 bot_panel.stats；老 Python 后端的
	# day/money/rep 不再显示（state.clients 也在关闸，这里同样不读）。
	var stats := UITheme.dict_of(bot_panel_data(), "stats")
	var today := Time.get_date_dict_from_system()
	var wx := 158.0 + _icon_at("time", Vector2(158, 29), Color("#7DC6FF"))
	UITheme.text_in(self, _font, Rect2(wx, 26, 84, 24),
			"今天 %02d-%02d" % [int(today.get("month", 1)), int(today.get("day", 1))],
			UITheme.BODY, Color("#7DC6FF"))
	UITheme.text_in(self, _font, Rect2(276, 26, 66, 24), String(state.get("clock", "--:--")), UITheme.BODY, C_DIM)
	UITheme.text_in(self, _font, Rect2(356, 26, 92, 24),
			"在线 %d 人" % int(stats.get("online", 0)), UITheme.BODY, C_GREEN)
	UITheme.text_in(self, _font, Rect2(452, 26, 92, 24),
			"今日 %d 单" % int(stats.get("doneToday", 0)), UITheme.BODY, C_GOLD)
	# 读宿主用量库失败时 tokens 是 null：只有这一格显示 —，其他格照常。
	# 只算 input + output，cacheRead/cacheWrite 不展示（不直观）。
	var tokens := UITheme.dict_of(stats, "tokens")
	var token_text := "今日 —"
	if not tokens.is_empty():
		token_text = "今日 %s tokens" % short_num(int(tokens.get("input", 0)) + int(tokens.get("output", 0)))
	UITheme.text_in(self, _font, Rect2(548, 26, 142, 24), token_text, UITheme.BODY, C_TXT)
	UITheme.button(self, day_button, day_button.has_point(get_local_mouse_position()))
	UITheme.button_text(self, _font, day_button, "结束当天", UITheme.SMALL, C_TXT)
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
	UITheme.text_in(self, _font, Rect2(x + 24, y + 20, w - 48, 28), "指令与待办", UITheme.TITLE, C_TXT)

	# 数据源换成真任务：bot_panel 里所有批次的所有 tasks。
	# 老 Python 后端的 state.clients 正在关闸，这里不再读它。
	var tasks: Array = []
	for batch in UITheme.arr_of(bot_panel_data(), "batches"):
		if batch is Dictionary:
			tasks.append_array(UITheme.arr_of(batch, "tasks"))
	if tasks.is_empty():
		UITheme.text_in(self, _font, Rect2(x + 24, y + 62, w - 48, 24),
				"还没有任务，对 Chief 说句话就会开工", UITheme.BODY, C_DIM)
		return

	# ★这里不再写死「只取前 5 条」。面板能放几行由高度算出来，放不下的靠滚轮翻，
	#   列表底部写明「第 a–b 条 / 共 N 条」，让人知道后面还有、也知道总共多少。
	var list_top := y + TASK_LIST_TOP
	_task_rect = Rect2(x + 12, list_top, w - 24, h - TASK_LIST_TOP - TASK_LIST_PAD)
	_task_total = tasks.size()
	_task_rows = maxi(1, int(_task_rect.size.y / TASK_ROW_H))
	var win := task_window(_task_total, _task_scroll, _task_rows)
	_task_scroll = int(win["scroll"])
	for row in int(win["count"]):
		var task: Dictionary = tasks[int(win["start"]) + row]
		var cy := list_top + row * TASK_ROW_H
		var st := String(task.get("status", ""))
		var line := "%s · %s" % [_text_of(task.get("bot_name", null)), String(task.get("title", ""))]
		UITheme.text_in(self, _font, Rect2(x + 24, cy, 214, 24), line, UITheme.BODY, C_TXT)
		# 状态徽标复用看板那一套，不另造颜色。
		UITheme.text_in(self, _font, Rect2(x + 242, cy, w - 266, 24),
				bot_badge(st), UITheme.SMALL, bot_color(st), HORIZONTAL_ALIGNMENT_RIGHT)
	if _task_total > int(win["count"]):
		UITheme.text_in(self, _font, Rect2(x + 24, y + h - 26, w - 48, 20),
				"第 %d–%d 条 / 共 %d 条 · 滚轮翻" % [
					int(win["start"]) + 1, int(win["start"]) + int(win["count"]), _task_total],
				UITheme.SMALL, C_DIM)


## 待办列表的可视窗口：从 start 起显示 count 行，scroll 已夹回合法范围。
##
## 抽成纯函数是为了能单独测——面板本体要字体、主题和真实尺寸，测起来很重，
## 而这里要守的只是「能放几行就放几行、滚到底能看到最后一条」。
static func task_window(total: int, scroll: int, max_rows: int) -> Dictionary:
	var rows := maxi(1, max_rows)
	var top := clampi(scroll, 0, maxi(0, total - rows))
	return {"start": top, "count": mini(rows, maxi(0, total - top)), "scroll": top}


## 滚轮翻待办列表。指针不在列表上就不吃事件（交给别处处理），返回是否吃掉。
func scroll_tasks(up: bool, at: Vector2) -> bool:
	if details_open or not _task_rect.has_point(at):
		return false
	var before := _task_scroll
	_task_scroll = clampi(_task_scroll + (-1 if up else 1), 0, maxi(0, _task_total - _task_rows))
	if _task_scroll == before:
		return false
	queue_redraw()
	return true


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


## 把可能缺失的字段读成字符串。
## ★GDScript 的 or 是纯布尔运算符：x or "" 只会得到 true/false，
##   String(true) 是 "True"、String(false) 是 "False" —— 都不是空串。
func _text_of(value, fallback := "") -> String:
	return fallback if value == null else String(value)


## Bot 面板只读；没有它时看板整个不画，老存档与未初始化状态都不受影响。
func bot_panel_data() -> Dictionary:
	var panel = state.get("bot_panel")
	if panel is Dictionary:
		return panel
	return {}


func bot_badge(status: String) -> String:
	match status:
		"idle": return "空闲"
		"queued": return "排队"
		"running": return "执行中"
		"waiting_for_tasks": return "等同事"
		"waiting_for_user": return "等你回复"
		"paused": return "已暂停"
		"done": return "完成"
		"failed": return "失败"
		"cancelled": return "已取消"
		"unknown": return "结果未知"
		_: return status


func bot_color(status: String) -> Color:
	match status:
		"done": return C_GREEN
		"running": return C_GOLD
		"queued": return Color("#7DC6FF")
		"waiting_for_tasks", "waiting_for_user", "paused": return Color("#B388FF")
		"failed", "unknown": return C_RED
		"cancelled": return C_DIM
		_: return C_DIM


## 看板每一行：真实团队的成员 + 它手上的活 + 状态。状态来自 bot_panel.staff，
## 不另造一份任务真源。
func _board_rows(panel: Dictionary) -> Array:
	var rows: Array = []
	var batches: Array = panel.get("batches", [])
	for member in panel.get("staff", []):
		var bot_id := String(member.get("bot_id", ""))
		var title := ""
		var request_id := ""
		for i in range(batches.size() - 1, -1, -1):
			var batch = batches[i]
			if not (batch is Dictionary):
				continue
			for task in batch.get("tasks", []):
				if String(task.get("bot_id", "")) == bot_id:
					title = String(task.get("title", ""))
					request_id = _text_of(batch.get("request_id", null))
					break
			if not title.is_empty():
				break
		rows.append({
			"name": String(member.get("name", "")),
			"title": title,
			"status": String(member.get("status", "idle")),
			"request_id": request_id,
		})
	# 没有团队信息时退回按批次列任务，老面板形状也能看。
	if rows.is_empty() and not batches.is_empty():
		var batch = batches[batches.size() - 1]
		for task in batch.get("tasks", []):
			rows.append({
				"name": _text_of(task.get("bot_name", null)),
				"title": String(task.get("title", "")),
				"status": String(task.get("status", "")),
				"request_id": _text_of(batch.get("request_id", null)),
			})
	return rows


## 打回按钮命中的办公室请求号（没有命中返回空串）。
func reject_at(screen: Vector2) -> String:
	for row in _reject_rects:
		if row.rect.has_point(screen):
			return String(row.request_id)
	return ""


func _draw_bot_board() -> void:
	bot_button = Rect2()
	_reject_rects.clear()
	if _chief_area:
		_chief_area.visible = false
	var panel := bot_panel_data()
	if panel.is_empty() or not bool(panel.get("ready", false)):
		return
	var batches: Array = panel.get("batches", [])
	var rows := _board_rows(panel)
	if batches.is_empty() and rows.is_empty():
		return
	# 面板高度按行数算，不再写死 118：标题区 36 + 每行 20 +「还有 N 项」20（仅在有剩余行时）
	# + 间隙 8 + 按钮 26 + 底部留白 8 ⇒ 3 行 138、4 行 158、4 行外还有剩余 178。
	# 行数上限按可用高度算：看板占地沿用旧面板的 118，扣掉标题区/间隙/按钮/底部留白后只剩 40（2 行），
	# 而看板是「一眼看当前批次」的 glance 面板（plan.md §3.2：最多 3–4 行 + 溢出提示），所以至少给 4 行；
	# 再多的行不静默丢弃，在最后一行下方提示「还有 N 项」。
	var max_rows := maxi(4, (118 - 36 - 8 - 26 - 8) / 20)
	var shown := mini(rows.size(), max_rows)
	var leftover := rows.size() - shown
	var board_h := 36 + shown * 20 + (20 if leftover > 0 else 0) + 8 + 26 + 8
	var r := Rect2(12, 74, 420, board_h)
	_panel(r)
	UITheme.text_in(self, _font, Rect2(r.position + Vector2(20, 12), Vector2(200, 24)),
			"真实任务 · Chief", UITheme.BODY, C_TXT)
	var tasks: Array = []
	if not batches.is_empty() and batches[batches.size() - 1] is Dictionary:
		tasks = batches[batches.size() - 1].get("tasks", [])
	var finished := 0
	for task in tasks:
		if String(task.get("status", "")) in ["done", "failed", "cancelled", "unknown"]:
			finished += 1
	if not tasks.is_empty():
		var summary_color := C_GOLD
		if finished == tasks.size():
			summary_color = C_GREEN
		UITheme.text_in(self, _font, Rect2(r.position + Vector2(r.size.x - 160, 12), Vector2(140, 24)),
				"%d/%d 收尾" % [finished, tasks.size()], UITheme.SMALL,
				summary_color, HORIZONTAL_ALIGNMENT_RIGHT)
	var i := 0
	for row in rows:
		if i >= shown:
			break
		var title := String(row.get("title", ""))
		if title.is_empty():
			title = "没有活"
		var line := "%s · %s" % [String(row.get("name", "")), title]
		UITheme.text_in(self, _font, Rect2(r.position + Vector2(20, 36 + i * 20), Vector2(206, 20)),
				UITheme.ellipsis(line, 15), UITheme.SMALL, C_TXT)
		var status := String(row.get("status", ""))
		UITheme.text_in(self, _font, Rect2(r.position + Vector2(228, 36 + i * 20), Vector2(76, 20)),
				bot_badge(status), UITheme.SMALL, bot_color(status), HORIZONTAL_ALIGNMENT_RIGHT)
		# 打回：意见会真的回到 Chief，由它重新派单（消耗一次模型调用）。
		var request_id := String(row.get("request_id", ""))
		if not request_id.is_empty():
			var br := Rect2(r.position + Vector2(r.size.x - 66, 34 + i * 20), Vector2(46, 20))
			UITheme.button(self, br, br.has_point(get_local_mouse_position()))
			UITheme.button_text(self, _font, br, "打回", UITheme.SMALL, C_TXT)
			_reject_rects.append({"request_id": request_id, "rect": br})
		i += 1
	# 放不下的行不静默丢弃：在最后一行下方用灰字提示还剩多少项。
	if leftover > 0:
		UITheme.text_in(self, _font, Rect2(r.position + Vector2(20, 36 + shown * 20), Vector2(206, 20)),
				"还有 %d 项" % leftover, UITheme.SMALL, UITheme.TEXT_DIM)
	bot_button = Rect2(r.position + Vector2(20, r.size.y - 32), Vector2(120, 26))
	UITheme.button(self, bot_button, false)
	UITheme.button_text(self, _font, bot_button, "对 Chief 说…", UITheme.SMALL, C_TXT)
	if _chief_area:
		_chief_area.position = bot_button.position
		_chief_area.size = bot_button.size
		_chief_area.visible = true


func _draw_toast() -> void:
	var vp := size
	var width := minf(vp.x - 432, maxf(360, _font.get_string_size(_toast_text, HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.BODY).x + 48))
	var lines := UITheme.preview_lines(_toast_text, int(width - 48), _font, UITheme.BODY, 3)
	var r := Rect2((vp.x - 416 - width) * .5, 76, width, maxf(1, lines.size()) * 26 + 48)
	UITheme.panel(self, r)
	for i in lines.size():
		UITheme.text_in(self, _font, Rect2(r.position + Vector2(24, 24 + i * 26), Vector2(width - 48, 26)), lines[i], UITheme.BODY, C_TXT)
