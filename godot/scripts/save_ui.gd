class_name SavePanel
extends Control
## M4-3 存档 / 读档面板
##
## 按 F5 开合。左边是存档列表（名字/天/在职/时间），
## 右边三个动作：立刻存档、读这一档、关掉。
##
## ★坏档**照样列出来**、标红"存档文件坏了"并可点——但点了会拿到后端的
##   友好错误提示。直接把坏档藏起来的话，玩家只会以为"我的存档丢了"。

signal closed()
signal save_requested(name)
signal load_requested(id)
signal toast(msg)
## F5 想打开时发出去——面板自己**没有数据**，列表是主控从后端拉的。
## 让面板自己开自己会拿到空列表，所以只发意图。
signal open_requested()

const W := 800.0
const H := 500.0
const ROW_H := 60.0
const PAD := 24.0
## 初始声誉：后端 stats.INIT_REP = 50（server/stats.py:63）。
## 新写出的存档声誉恒等于它，旧存档靠这一点认出来——见 _is_legacy()。
const INIT_REP := 50
## 旧存档提示语（详情区）。旧档不迁移、不删除，只是读的时候说一声。
const LEGACY_HINT := "旧版存档：客户与资金记录不再使用"

var saves: Array = []
var _font: Font
var _btns: Array = []          # {id, rect, who}
var _hover := ""
var _sel := ""                 # 当前选中的存档 id
var _list_rect := Rect2()
var _scroll_index := 0


func _ready() -> void:
	_font = ThemeDB.fallback_font
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	set_process(true)


func _process(_d: float) -> void:
	queue_redraw()


## 只灌数据，不显示。
##
## ★为什么要和 open() 分开：主控在 _ready 里会调一次 api_saves() 拉列表，
##   回调里如果直接 open()，**存档面板就在启动那一刻自己弹出来**，
##   盖住大半个办公室——玩家第一次看到的就是一个模态框。
##   拉列表和显示是两件事，这里分成两个入口。
func set_list(list_data: Array) -> void:
	saves = list_data
	if _sel == "":
		for s in saves:
			if s.get("ok"):
				_sel = String(s.get("id", ""))
				break
	_layout()
	queue_redraw()


func open(list_data: Array) -> void:
	set_list(list_data)
	# 默认选中第一个能用的
	_sel = ""
	for s in saves:
		if s.get("ok"):
			_sel = String(s.get("id", ""))
			break
	visible = true
	queue_redraw()


## ★按钮矩形与点击区的唯一来源。
##
## 原来这些是在 `_draw` 里算的——也就是**输入依赖渲染**。后果是：
## `open()` 之后还没等到下一帧，`_btns` 是空的，点了没反应；
## 面板隐藏时 `_draw` 直接 return，点击区还留着上一份陈旧数据。
## 现在把布局单独拎出来：open / 选中变化 / 直接 draw 都调它。
func _layout() -> void:
	_btns.clear()
	if not visible:
		return
	var r := _panel_rect()
	var lx := r.position.x + PAD
	var ly := r.position.y + 70
	var lw := W - PAD * 2 - 176 - 20
	_list_rect = Rect2(lx, ly, lw, H - 70 - 54)
	var max_rows := int((_list_rect.size.y - 36) / ROW_H)
	_scroll_index = clampi(_scroll_index, 0, maxi(0, saves.size() - max_rows))
	var shown := mini(max_rows, saves.size() - _scroll_index)
	for i in shown:
		var sid := String(saves[_scroll_index + i].get("id", ""))
		_btns.append({"id":"sel:" + sid, "rect":Rect2(lx, ly + 36 + i * ROW_H, lw, ROW_H - 4), "who":sid})
	var bx := r.end.x - PAD - 176
	var by := r.position.y + 70
	for i in 3:
		_btns.append({"id":["save:0", "load:0", "close:0"][i], "rect":Rect2(bx, by + i * 48, 176, 38), "who":""})


func _panel_rect() -> Rect2:
	return Rect2((size.x - W) * 0.5, (size.y - H) * 0.5, W, H)


func close() -> void:
	visible = false
	_btns.clear()
	closed.emit()


func _input(e: InputEvent) -> void:
	# ★F5 必须放在 `if not visible: return` **之前**。
	#   原来那行 return 写在最前面，于是 F5 在隐藏状态下直接被吃掉——
	#   面板**永远打不开**，只能关。真实 bug，测试立刻抓到了。
	if e is InputEventKey and e.pressed and not e.echo \
			and (e as InputEventKey).keycode == KEY_F5:
		if visible:
			close()
		else:
			open_requested.emit()      # 打开需要数据，由主控去拉
		accept_event()
		return
	if not visible:
		return
	if e is InputEventKey and e.pressed and e.keycode == KEY_ESCAPE:
		close()
		accept_event()
		return
	if not (e is InputEventMouseMotion):
		return
	var pos: Vector2 = (e as InputEventMouseMotion).position
	var h := ""
	for b in _btns:
		if b["rect"].has_point(pos):
			h = String(b["id"])
	if h != _hover:
		_hover = h
		queue_redraw()


func _gui_input(e: InputEvent) -> void:
	if not visible:
		return
	if not (e is InputEventMouseButton):
		return
	var mb := e as InputEventMouseButton
	if mb.pressed and mb.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN] and _list_rect.has_point(mb.position):
		_scroll_index += -1 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1
		_layout()
		queue_redraw()
		accept_event()
		return
	if not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	for b in _btns:
		if not b["rect"].has_point(mb.position):
			continue
		match String(b["id"]).split(":")[0]:
			"save":
				# 自动档不能手动覆盖，改名存成手动档
				var name := "手动存档"
				for s in saves:
					if String(s.get("id", "")) == _sel:
						name = "第%s天改前" % str(s.get("day", "?"))
						break
				save_requested.emit(name)
			"load":
				# ★必须再判一次可用性。按钮是手搓画的，"禁用"只是外观，
				#   引擎不会替我拦住点击——不判的话对着坏档点一下就真发读档请求了。
				if _sel != "" and _sel_is_ok():
					load_requested.emit(_sel)
				else:
					toast.emit("这个存档读不了：%s"
							% String(_current().get("msg", "存档不可用")))
			"sel":
				_sel = String(b["id"]).split(":", 1)[1]
				_layout()
				queue_redraw()
			"close":
				close()
		accept_event()
		return


func _draw() -> void:
	if not visible:
		return
	_layout()
	var r := _panel_rect()
	UITheme.panel(self, r, UITheme.BG, UITheme.ACCENT)
	UITheme.text_in(self, _font, Rect2(r.position + Vector2(PAD, PAD), Vector2(W - 200, 24)), "存档 / 读档", 16, UITheme.TEXT)
	UITheme.text_in(self, _font, Rect2(r.end.x - PAD - 140, r.position.y + PAD, 140, 24), "F5 / Esc 关闭", 11, UITheme.TEXT_FAINT, HORIZONTAL_ALIGNMENT_RIGHT)

	var lx := _list_rect.position.x
	var ly := _list_rect.position.y
	var lw := _list_rect.size.x
	var split := lw * .42
	UITheme.text_in(self, _font, Rect2(lx + 12, ly, split - 24, 16), "存档", 10, UITheme.TEXT_FAINT)
	UITheme.text_in(self, _font, Rect2(lx + split + 12, ly, lw - split - 24, 16), "天 / 在职 / 时间", 10, UITheme.TEXT_FAINT)
	UITheme.text_in(self, _font, Rect2(lx + split + 12, ly + 16, lw - split - 24, 16), "时间 · 类型", 10, UITheme.TEXT_FAINT)
	var shown := 0
	for button in _btns:
		if not str(button.id).begins_with("sel:"):
			continue
		var s: Dictionary = saves[_scroll_index + shown]
		shown += 1
		var sid := str(s.get("id", ""))
		var row: Rect2 = button.rect
		var usable := bool(s.get("ok", false))
		UITheme.panel(self, row, UITheme.BG, UITheme.ACCENT if sid == _sel else UITheme.EDGE, .22)
		var tag := "自动" if s.get("auto") else "手动"
		# 旧存档（经营玩法停用前留下的）标一下，玩家一眼能认出。
		# 坏档不标——它已经写着"存档文件坏了"，再叠一个标记只是噪音。
		if usable and _is_legacy(s):
			tag += "·旧版"
		UITheme.text_in(self, _font, Rect2(row.position + Vector2(12, 12), Vector2(split - 24, 18)), "%s [%s]" % [str(s.get("name", sid)), tag], 12, UITheme.TEXT if usable else UITheme.TEXT_FAINT)
		UITheme.text_in(self, _font, Rect2(row.position + Vector2(split + 12, 12), Vector2(lw - split - 24, 18)), "第 %s 天 · 在职 %s 人 · %s" % [str(s.get("day", "?")), str(s.get("workers_left", "?")), str(s.get("saved_at_str") or "—")], 11, UITheme.TEXT_DIM)
		UITheme.text_in(self, _font, Rect2(row.position + Vector2(split + 12, 32), Vector2(lw - split - 24, 14)), "%s · %s" % [str(s.get("saved_at_str", "")), str(s.get("why", ""))], 10, UITheme.TEXT_FAINT if usable else UITheme.DANGER)
		if not usable:
			UITheme.text_in(self, _font, Rect2(row.position + Vector2(12, 32), Vector2(split - 24, 14)), "存档文件坏了：" + str(s.get("msg", "")), 10, UITheme.DANGER)
	if saves.is_empty():
		UITheme.text_in(self, _font, Rect2(lx + 12, ly + 54, lw - 24, 20), "还没有任何存档。每天结束当天时会自动存一份。", 12, UITheme.TEXT_DIM)
	else:
		UITheme.text_in(self, _font, Rect2(lx, r.end.y - 44, lw, 20), "显示 %d–%d / %d · 滚轮查看更多" % [_scroll_index + 1, _scroll_index + shown, saves.size()], 10, UITheme.TEXT_FAINT)

	var bx := r.end.x - PAD - 176
	var by := r.position.y + 70
	_btn(Rect2(bx, by, 176, 38), "save:0", "立刻存档", true)
	_btn(Rect2(bx, by + 48, 176, 38), "load:0", "读这一档", _sel != "" and _sel_is_ok())
	_btn(Rect2(bx, by + 96, 176, 38), "close:0", "关闭", true)
	var cur := _current()
	if not cur.is_empty():
		var dy := by + 156
		# ★不再显示"资金/声誉"：经营玩法停用后这两个数不再进账，
		#   摆在那儿只会让人以为钱还在涨。旧档另给一句提示（见 _is_legacy）。
		var fields := ["存档名：%s" % str(cur.get("name", "—")),
			"第 %s 天 · 在职 %s 人" % [str(cur.get("day", "—")), str(cur.get("workers_left", "—"))],
			"保存于 %s" % str(cur.get("saved_at_str", "—")),
			"原因：%s" % str(cur.get("why", "—"))]
		for field in fields:
			for line in UITheme.preview_lines(field, 176, _font, 11, 2):
				UITheme.text_in(self, _font, Rect2(bx, dy, 176, 18), line, 11, UITheme.TEXT_DIM)
				dy += 18
			dy += 8
		# 旧存档：说清楚它是旧档、客户与资金记录不再使用（不迁移、不删除）。
		if bool(cur.get("ok", false)) and _is_legacy(cur):
			for line in UITheme.preview_lines(LEGACY_HINT, 176, _font, 11, 2):
				UITheme.text_in(self, _font, Rect2(bx, dy, 176, 18), line, 11, UITheme.TEXT)
				dy += 18


## enabled   = 这个动作当前能不能执行（决定外观）
## clickable = 是否注册点击区。**默认跟随 enabled，但可以分开**——
##             "关闭"就是 enabled=true、clickable=false（外观弱一点但照样能点）。
func _btn(r: Rect2, id: String, label: String, enabled: bool,
		clickable := true) -> void:
	var hovered := _hover == id
	UITheme.button(self, r, hovered and enabled)
	UITheme.button_text(self, _font, r, label, 12,
			UITheme.TEXT if enabled else UITheme.TEXT_FAINT)
	# 点击区由 _layout() 统一登记，这里只画外观。
	# 留着这条会让"登记"有两个来源，_draw 每帧重画时把 _layout 的结果冲掉。


func _current() -> Dictionary:
	for s in saves:
		if String(s.get("id", "")) == _sel:
			return s
	return {}


func _sel_is_ok() -> bool:
	var c := _current()
	return not c.is_empty() and bool(c.get("ok", false))


## ★这是不是旧存档？（经营玩法停用前留下的那种）
##
## 判据：**rep（声誉）是数字，且不等于 50**。
##
## 为什么只能这么判（依据全在后端代码里）：
##   - 面板拿到的是列表接口给的那几项：list_saves()（server/save.py:382）只给
##     id/ok/msg/name/auto/why/day/money/rep/workers_left/saved_at_str。
##     存档文件里真正一眼就能认出旧档的 "format"（版本号，server/save.py:96）
##     和 "clients"（server/save.py:113）**面板都拿不到**。
##   - 声誉是唯一还能用的信号：改声誉的三处全是客户事件——验收 +rg
##     （server/game.py:919）、打回 -5（server/game.py:924）、客户流失 -3
##     （server/game.py:1296）；而客户系统已经停用（server/game.py:1337 注释：
##     不再来客户，tick 不再调用 spawn_client），所以**新写出的存档声誉恒等于
##     初始值 stats.INIT_REP = 50**（server/stats.py:63）。旧存档只要接过、打回
##     或丢过任何一单，声誉就不是 50。
##
## ★这个判据是**单向**的：声誉还是 50 的旧档（从头到尾没完成过一单）认不出来。
##   宁可漏认也不误认——误认会让玩家以为自己的新存档坏了。
##   另外：读旧档会把声誉一起读回来（server/save.py:164 `game.rep = d["rep"]`），
##   之后新存的档也带着这个旧数值，于是也会被标成旧版——这不算误认，
##   它确实带着旧档的数据。
func _is_legacy(s: Dictionary) -> bool:
	var rep: Variant = s.get("rep", null)
	if typeof(rep) != TYPE_INT and typeof(rep) != TYPE_FLOAT:
		return false		# 坏档没有数值声誉（list_saves 给的是 "?"）
	return int(rep) != INIT_REP


## 测试用：直接塞列表并选中
func debug_set(list_data: Array, sel := "") -> void:
	saves = list_data
	_sel = sel if sel != "" else (String(list_data[0].get("id", ""))
			if not list_data.is_empty() else "")
	visible = true
	_layout()


func debug_state() -> Dictionary:
	return {"visible": visible, "sel": _sel, "n": saves.size(),
			"sel_ok": _sel_is_ok(),
			"legacy": _is_legacy(_current()),
			"btns": _btns.size(),
			"ids": _btns.map(func(b): return String(b["id"]))}
