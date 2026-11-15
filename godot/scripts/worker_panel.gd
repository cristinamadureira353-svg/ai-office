class_name WorkerPanel
extends Control
## 角色指令面板（DESIGN 9.2「点角色」）
##
## 左下常驻：列出五个员工的状态条；点一个展开详情和指令。
## 指令：去休息 / 去摸鱼 / 开会 / 跟他说话（打开 ChatPanel）。
## 所有可点区域都有悬停反馈，Esc 关闭展开。

signal cmd_requested(who, action, arg)
signal chat_requested(who)
signal selection_changed(who)
signal utility_requested(action)
signal feedback(message)

var workers: Array = []
## 找不到干净的主管位位置时，Chief 只在这里以只读条目出现，不占工位行。
var chief_fallback := false
var chief_entry: Dictionary = {}
var selected := ""
var state: Dictionary = {}
var _font: Font
var _bars: Array = []          # {id, rect, data}
var _vacant: Array = []         # 空工位：{slot, rect}
var _overflow: Array = []       # 超出工位上限的人：{extra, rect}
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
	_vacant.clear()
	_overflow.clear()
	_btns.clear()
	_chat_buttons.clear()
	_utility_buttons.clear()
	_disabled_btns.clear()
	var list := _list_rect()
	UITheme.panel(self, list)
	UITheme.text_in(self, _font, Rect2(list.position + Vector2(20, 16), Vector2(312, 24)), "员工 · 点卡片查看指令", UITheme.BODY, UITheme.TEXT)
	if chief_fallback and not chief_entry.is_empty():
		# 主管位没有干净位置时，Chief 只作为只读条目出现，不占工位行。
		var chip := Rect2(list.position + Vector2(172, 12), Vector2(148, 30))
		UITheme.panel(self, chip, Color(0, 0, 0, .12), UITheme.EDGE, .22)
		UITheme.text_in(self, _font, chip.grow(-8),
				"%s · %s" % [String(chief_entry.get("name", "Chief")), String(chief_entry.get("role", "总管"))],
				UITheme.SMALL, UITheme.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER)
	UITheme.text_in(self, _font, Rect2(list.position + Vector2(336, 16), Vector2(list.size.x - 628, 24)), "Q/E 切换区域 · O 全景 · C 聊天", UITheme.SMALL, UITheme.TEXT_DIM)
	# 三个工具按钮：存档、关系、团队设置。整体左移 128 给第三个腾位置。
	for i in 3:
		var action: String = ["save", "relations", "team"][i]
		var button := Rect2(list.end.x - 400 + i * 128, list.position.y + 12, 120, 32)
		UITheme.button(self, button, _hover == "utility:" + action)
		UITheme.button_text(self, _font, button, ["存档 F5", "关系 Tab", "团队设置"][i], UITheme.SMALL, UITheme.TEXT)
		_utility_buttons.append({"id":action, "rect":button})
	var card_w := (list.size.x - 40 - 40) / 5
	var staff := _staff_rows()
	if staff.is_empty():
		# 没有真实 Bot 团队：保留原来的五个默认员工。没初始化过 Bot 的玩家，
		# 办公室不能因此变空。
		for i in range(5):
			var r := Rect2(list.position.x + 20 + i * (card_w + 10), list.position.y + 52, card_w, 88)
			var who := String(workers[i].get("id", "")) if i < workers.size() else ""
			if not who.is_empty():
				_draw_row(r, who, who == selected)
	else:
		# 工位跟着真实 Bot 团队走：名字是 Bot 的名字，小人随机分配。
		var shown := mini(staff.size(), 4)
		for i in shown:
			var r := Rect2(list.position.x + 20 + i * (card_w + 10), list.position.y + 52, card_w, 88)
			_draw_staff_row(r, staff[i], String(staff[i].get("slot", "")) == selected)
		var slot_index := shown
		if staff.size() > 4:
			# 工位只有五个，多出来的人合成一个「+N」。
			var r := Rect2(list.position.x + 20 + slot_index * (card_w + 10), list.position.y + 52, card_w, 88)
			_draw_more_row(r, staff.size() - 4)
			slot_index += 1
		for slot in _empty_slots():
			if slot_index >= 5:
				break
			var r := Rect2(list.position.x + 20 + slot_index * (card_w + 10), list.position.y + 52, card_w, 88)
			_draw_empty_row(r, String(slot))
			slot_index += 1
	_sb.visible = not selected.is_empty()
	if selected.is_empty():
		return
	_draw_detail(selected)


## 真实 Bot 团队的成员行；没有面板或还没建 Bot 时返回空（保留默认五个员工）。
func _staff_rows() -> Array:
	var panel = state.get("bot_panel")
	if not (panel is Dictionary):
		return []
	if not bool(panel.get("ready", false)):
		return []
	var staff: Array = panel.get("staff", [])
	return staff if not staff.is_empty() else []


## 空着的工位：等一个真实 Bot 补上。
func _empty_slots() -> Array:
	var panel = state.get("bot_panel")
	if not (panel is Dictionary):
		return []
	var slots: Array = panel.get("empty_slots", [])
	return slots


## 详情里的模型行：这个 Bot 到底跑在哪个模型上（没配模型就是跟随宿主默认）。
func detail_model_line(who: String) -> String:
	var staff := _staff_of(who)
	if staff.is_empty():
		return ""
	return "模型：%s" % String(staff.get("model_label", ""))


## 某个工位上的真实 Bot（没有就是空字典）。
func _staff_of(slot: String) -> Dictionary:
	for item in _staff_rows():
		if String(item.get("slot", "")) == slot:
			return item
	return {}


func _list_rect() -> Rect2:
	return Rect2(24, size.y - 172, size.x - 48, 160)


func _panel_rect() -> Rect2:
	return Rect2(size.x - 396, 76, 380, 468)


func _has_point(point: Vector2) -> bool:
	return _list_rect().has_point(point) or (not selected.is_empty() and _panel_rect().has_point(point))


## 这名员工绑定的真实 Bot 当前在做什么；没有绑定或没有面板时返回空。
func _bot_status(who: String) -> String:
	var panel = state.get("bot_panel")
	if not (panel is Dictionary):
		return ""
	if not bool(panel.get("ready", false)):
		return ""
	var stale = panel.get("stale")
	if stale is Dictionary and stale.has(who):
		return "stale"
	return String(_bot_task(who).get("status", ""))


## 这个工位上的真实 Bot 手上那单：{"status": 状态, "title": 任务标题}。
## 绑上了但手上没活 ⇒ {"status": "idle"}；没绑定或没有面板 ⇒ 空字典。
func _bot_task(who: String) -> Dictionary:
	var panel = state.get("bot_panel")
	if not (panel is Dictionary) or not bool(panel.get("ready", false)):
		return {}
	var bindings = panel.get("bindings")
	if not (bindings is Dictionary) or not bindings.has(who):
		return {}
	var bot_id := String(bindings[who])
	if bot_id.is_empty():
		return {}
	var batches: Array = panel.get("batches", [])
	var i := batches.size() - 1
	while i >= 0:
		var batch = batches[i]
		if batch is Dictionary:
			for task in batch.get("tasks", []):
				if String(task.get("bot_id", "")) == bot_id:
					return {"status": String(task.get("status", "")),
						"title": String(task.get("title", ""))}
		i -= 1
	return {"status": "idle", "title": ""}


## 状态条要的真 Bot 状态：状态 / 手上的活。
## 字段一律防御性读取：后端正在改，快照里少一个字段就退到默认值。
func _bot_info(who: String) -> Dictionary:
	var task := _bot_task(who)
	return {
		"status": String(task.get("status", "")),
		"title": String(task.get("title", "")),
	}


func _bot_badge_text(status: String) -> String:
	match status:
		"stale": return "未绑定"
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


func _bot_badge_color(status: String) -> Color:
	match status:
		"done": return UITheme.GOOD
		"running": return UITheme.WARN
		"queued", "idle": return UITheme.TEXT_DIM
		"waiting_for_tasks", "waiting_for_user", "paused": return Color("#B388FF")
		"failed", "unknown", "stale": return UITheme.BAD
		_: return UITheme.TEXT_DIM


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
	# 真实 Bot 状态贴在状态行右侧，不影响原有的体力/心情/宕机显示。
	var bot_status := _bot_status(who)
	if not bot_status.is_empty():
		UITheme.text_in(self, _font, Rect2(x, r.position.y + 38, width - 4, 22),
				"[%s]" % _bot_badge_text(bot_status), UITheme.SMALL,
				_bot_badge_color(bot_status), HORIZONTAL_ALIGNMENT_RIGHT)

	# 体力/心情那两条杠删了：旧经营玩法下线后体力恒定满格（纯噪音），
	# 心情只剩团建时会跳一下。腾出来的位置显示真任务标题——这才是玩家
	# 想在概览上看到的东西。
	var task_title := String(_bot_task(who).get("title", ""))
	if task_title.is_empty():
		task_title = "手上没活"
	UITheme.text_in(self, _font, Rect2(x, r.position.y + 66, width, 22),
			UITheme.fit(task_title, width, _font, UITheme.SMALL), UITheme.SMALL, UITheme.TEXT_DIM)


## 一个真实 Bot 占的工位：标题是 Bot 的名字，右边小字是它在团队里的角色。
func _draw_staff_row(r: Rect2, staff: Dictionary, sel: bool) -> void:
	var slot := String(staff.get("slot", ""))
	var w := _worker(slot)
	var col := UITheme.worker_color(slot)
	var hovered := _hover == "row:" + slot
	UITheme.panel(self, r, UITheme.BG if not sel else Color("#1e2636"),
			col if sel else (UITheme.EDGE_HI if hovered else UITheme.EDGE), .22)
	if sel:
		draw_rect(r.grow(-7), Color(col, .12))
		draw_rect(r.grow(-5), col, false, 2)
	_bars.append({"id": "row:" + slot, "rect": r})

	UITheme.portrait(self, slot, Rect2(r.position + Vector2(12, 12), Vector2(32, 48)))
	var x := r.position.x + 56
	var width := r.size.x - 68
	UITheme.text_in(self, _font, Rect2(x, r.position.y + 10, width - 58, 24),
			UITheme.ellipsis(String(staff.get("name", slot)), 8), UITheme.SMALL, col)
	var chat_rect := Rect2(r.end.x - 62, r.position.y + 8, 50, 30)
	var down := bool(w.get("brain_down", false))
	UITheme.button(self, chat_rect, _hover == "chat:" + slot, not down)
	UITheme.button_text(self, _font, chat_rect, "聊天", UITheme.SMALL, UITheme.TEXT_FAINT if down else UITheme.TEXT)
	_chat_buttons.append({"who":slot, "rect":chat_rect, "down":down})
	# 真实 Bot 状态在左，角色标签在右——两件事各占一行同一格的两端。
	var status := String(staff.get("status", ""))
	if not status.is_empty():
		UITheme.text_in(self, _font, Rect2(x, r.position.y + 38, width - 96, 22),
				"[%s]" % _bot_badge_text(status), UITheme.SMALL, _bot_badge_color(status))
	UITheme.text_in(self, _font, Rect2(x, r.position.y + 38, width, 22),
			UITheme.ellipsis(String(staff.get("role", "")), 6), UITheme.SMALL, UITheme.TEXT_DIM,
			HORIZONTAL_ALIGNMENT_RIGHT)

	# 这个工位上的 Bot 实际跑在哪个模型上；没配模型就是跟随宿主默认。
	# 卡片只写模型名本身，不带「模型：」前缀——完整写法在详情页 detail_model_line()。
	# 窄视口下这行只有 70 多像素，带前缀会被 fit() 截成省略号，一眼看不出是哪个模型。
	# 宽度与名字那行一致（width - 58），右侧留给「聊天」按钮；text_in 内部按
	# rect 宽度截断加省略号，模型名再长也不会越过按钮。
	var model_label := String(staff.get("model_label", ""))
	var model_text := model_label if not model_label.is_empty() else "默认"
	UITheme.text_in(self, _font, Rect2(x, r.position.y + 64, width - 58, 22),
			model_text, UITheme.SMALL, UITheme.TEXT_DIM)


## 空工位：虚线框 + 待招募，等一个真实 Bot 补上。
func _draw_empty_row(r: Rect2, slot: String) -> void:
	_vacant.append({"slot": slot, "rect": r})
	UITheme.panel(self, r, Color(0, 0, 0, .10), UITheme.EDGE, .22)
	var inner := r.grow(-8)
	_dashed_rect(inner, UITheme.TEXT_FAINT)
	UITheme.text_in(self, _font, Rect2(r.position + Vector2(12, 28), Vector2(r.size.x - 24, 24)),
			"待招募", UITheme.SMALL, UITheme.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER)
	UITheme.text_in(self, _font, Rect2(r.position + Vector2(12, 50), Vector2(r.size.x - 24, 22)),
			"还没有 Bot 占这个位置", UITheme.SMALL, UITheme.TEXT_FAINT, HORIZONTAL_ALIGNMENT_CENTER)


## 超过工位上限的人合成一张卡。
func _draw_more_row(r: Rect2, extra: int) -> void:
	_overflow.append({"extra": extra, "rect": r})
	UITheme.panel(self, r, Color(0, 0, 0, .10), UITheme.EDGE, .22)
	UITheme.text_in(self, _font, Rect2(r.position + Vector2(12, 28), Vector2(r.size.x - 24, 26)),
			"+%d" % extra, UITheme.TITLE, UITheme.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER)
	UITheme.text_in(self, _font, Rect2(r.position + Vector2(12, 54), Vector2(r.size.x - 24, 22)),
			"人更多了", UITheme.SMALL, UITheme.TEXT_FAINT, HORIZONTAL_ALIGNMENT_CENTER)


func _dashed_rect(r: Rect2, col: Color) -> void:
	draw_dashed_line(r.position, Vector2(r.end.x, r.position.y), col, 1.0, 6.0)
	draw_dashed_line(Vector2(r.end.x, r.position.y), r.end, col, 1.0, 6.0)
	draw_dashed_line(r.end, Vector2(r.position.x, r.end.y), col, 1.0, 6.0)
	draw_dashed_line(Vector2(r.position.x, r.end.y), r.position, col, 1.0, 6.0)


func _draw_detail(who: String) -> void:
	var w := _worker(who)
	var r := _panel_rect()
	var pw := r.size.x
	UITheme.panel(self, r, UITheme.BG, UITheme.worker_color(who))
	var x := r.position.x + 24
	# 选中的是真实 Bot 时，标题用 Bot 的名字与角色。
	var staff := _staff_of(who)
	var display_name := UITheme.name_of(who)
	var display_role := String(w.get("tag", ""))
	if not staff.is_empty():
		display_name = String(staff.get("name", display_name))
		display_role = String(staff.get("role", ""))
	UITheme.text_in(self, _font, Rect2(x, r.position.y + 20, pw - 48, 28), "%s · %s" % [display_name, display_role],
			UITheme.TITLE, UITheme.worker_color(who))
	UITheme.portrait(self, who, Rect2(r.position + Vector2(pw - 76, 58), Vector2(52, 78)))
	# 这个 Bot 到底跑在哪个模型上——没配模型就是跟着宿主走。
	var model_line := detail_model_line(who)
	if not model_line.is_empty():
		UITheme.text_in(self, _font, Rect2(x, r.position.y + 48, pw - 126, 22),
				model_line, UITheme.SMALL, UITheme.TEXT_DIM)
	var lines := UITheme.preview_lines(String(w.get("blurb", "")), int(pw - 126), _font, UITheme.SMALL, 2)
	for i in lines.size():
		UITheme.text_in(self, _font, Rect2(x, r.position.y + 72 + i * 22, pw - 126, 22), lines[i], UITheme.SMALL, UITheme.TEXT_DIM)

	# 复用状态条组件，保证和左下列表同一套刻度。
	# ★节点只在 _ready 建一次：_draw 里 new 一个再把旧的 free 掉，
	#   等于每帧建一次节点，redraw 频繁时会把场景树堆满。
	var sb := _sb
	sb.set_worker(w)
	sb.set_bot(_bot_info(who))
	sb.position = Vector2(x, r.position.y + 118)
	sb.size = Vector2(StatsBar.W, sb.total_height())

	# 这一行说的是真 Bot 此刻在干什么。旧经营玩法（客户 / 接单）已停用，
	# 不再报"正在服务一个客户"，也不承诺"暂停接单"这种已经不存在的活。
	var bot_status := String(_bot_task(who).get("status", ""))
	var blurb := "手上没活"
	if bot_status == "running":
		blurb = "正在处理任务"
	if w.get("brain_down", false):
		blurb = "脑袋宕机了 · 暂停行动"
	UITheme.text_in(self, _font, Rect2(x, r.position.y + 180, pw - 48, 22), blurb, UITheme.SMALL,
			UITheme.BAD if w.get("brain_down", false) else UITheme.TEXT)
	var y := r.position.y + 210
	if w.get("brain_down", false):
		var checking := bool(w.get("brain_checking", false))
		_button(Rect2(x, y, pw - 48, 44), "正在检查恢复…" if checking else "额度恢复后 · 重启脑袋", "reboot", who, not checking)
		UITheme.text_in(self, _font, Rect2(x, y + 58, pw - 48, 22), "重启只检测一次，不会反复调用。", UITheme.SMALL, UITheme.TEXT_DIM)
		UITheme.text_in(self, _font, Rect2(x, r.end.y - 38, pw - 48, 22), "Esc 收起 · 其他员工仍可工作", UITheme.SMALL, UITheme.TEXT_FAINT)
		return
	_button(Rect2(x, y, pw - 48, 44), "与 %s 聊天" % display_name, "chat", who)
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
