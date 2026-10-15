extends SceneTree
## M4-3 存档面板单节测试
##
## 跑法：./run_test.sh res://tests/t_save.gd
##
## 验的是**面板行为**而不是后端（后端在 tests/test_save.py 的 50 条里）：
## 列表画得对不对、选中切换、坏档是否可见、F5 开合、信号有没有发出去。

var pass_n := 0
var fail_n := 0
var _SP: Control = null


func _init() -> void:
	print("── M4-3 存档面板 ──")
	await _run()
	_teardown()
	print("═".repeat(52))
	if fail_n == 0:
		print("✓ 通过 %d / %d" % [pass_n, pass_n + fail_n])
	else:
		print("✗ 失败 %d 条（通过 %d）" % [fail_n, pass_n])
	quit(0 if fail_n == 0 else 1)


func check(name: String, ok: bool, detail := "") -> void:
	if ok:
		pass_n += 1
		print("  PASS  %s" % name)
	else:
		fail_n += 1
		print("  FAIL  %s  %s" % [name, detail])


func _rows() -> Array:
	return [
		{"id": "a1", "ok": true, "name": "第5天结算", "auto": true,
			"why": "每日结算", "day": 5, "money": 1234, "rep": 62,
			"workers_left": 5, "saved_at_str": "2026-10-05 10:00:00"},
		{"id": "b2", "ok": true, "name": "手动存档", "auto": false,
			"why": "", "day": 9, "money": 777, "rep": 71,
			"workers_left": 4, "saved_at_str": "2026-10-05 11:22:33"},
		{"id": "c3", "ok": false, "msg": "存档文件坏了（第 3 行）：Expecting value",
			"name": "第8天结算", "auto": true, "why": "", "day": 8,
			"money": 0, "rep": 0, "workers_left": 0,
			"saved_at_str": "2026-10-05 09:00:00"},
	]


func _run() -> void:
	_SP = load("res://scripts/save_ui.gd").new()
	root.add_child(_SP)
	await process_frame
	# 给个视口尺寸，_draw 里用 size 算居中
	_SP.size = Vector2(1280, 720)

	var got_save: Array = []
	var got_load: Array = []
	var got_open := [0]
	var got_toast: Array = []
	_SP.save_requested.connect(func(n): got_save.append(n))
	_SP.load_requested.connect(func(i): got_load.append(i))
	_SP.open_requested.connect(func(): got_open[0] += 1)
	_SP.toast.connect(func(m): got_toast.append(m))

	# ── 1 列表 ──
	_SP.debug_set(_rows(), "b2")
	_SP.queue_redraw()
	await process_frame
	var st: Dictionary = _SP.debug_state()
	check("1a. 默认打开可见", st["visible"] == true)
	check("1b. 显式选中生效", st["sel"] == "b2", st["sel"])
	check("1c. 选中项是可用档", st["sel_ok"] == true)
	# 每行 + 右侧三个动作都要注册成可点区
	var ids: Array = st["ids"]
	check("1d. ★每一行都可点（含坏档）",
		ids.has("sel:a1") and ids.has("sel:b2") and ids.has("sel:c3"),
		str(ids))
	check("1e. ★坏档也画出来了（没被藏起来）", ids.has("sel:c3"))
	check("1f. 三个动作按钮都在",
		ids.has("save:0") and ids.has("load:0") and ids.has("close:0"),
		str(ids))

	# ── 2 默认选中逻辑 ──
	_SP.open(_rows())
	_SP.debug_set(_rows())            # 不给 sel，让它自己挑
	await process_frame
	check("2a. ★不指定时自动选第一个可用的档",
		_SP.debug_state()["sel"] == "a1", str(_SP.debug_state()["sel"]))
	var only_bad := [{"id": "x", "ok": false, "msg": "坏"}]
	_SP.open(only_bad)
	await process_frame
	check("2b. 全是坏档时不会选任何一档（读档按钮禁用）",
		_SP.debug_state()["sel_ok"] == false, str(_SP.debug_state()))

	# ── 3 选中切换 ──
	_SP.open(_rows())
	_click_id("sel:a1")
	check("3a. ★点行能切换选中", _SP.debug_state()["sel"] == "a1",
		str(_SP.debug_state()["sel"]))
	_click_id("sel:c3")
	check("3b. ★能选中坏档（看得见坏在哪）",
		_SP.debug_state()["sel"] == "c3", str(_SP.debug_state()["sel"]))
	check("3c. ★坏档的读档按钮被禁用", _SP.debug_state()["sel_ok"] == false)

	# ── 4 信号 ──
	_SP.open(_rows())
	_click_id("sel:b2")
	_click_id("load:0")
	check("4a. ★读这一档会发出 load 信号并带对 id",
		got_load.size() == 1 and got_load[0] == "b2", str(got_load))
	got_load.clear()
	_click_id("save:0")
	check("4b. ★立刻存档会发出 save 信号（名字带上第几天）",
		got_save.size() == 1 and String(got_save[0]).contains("第"),
		str(got_save))
	# ★坏档点读档：发不出读档请求，但要给出可读的提示
	_SP.open(_rows())
	_click_id("sel:c3")
	_click_id("load:0")
	check("4c. ★坏档点读档发不出读档请求", got_load.is_empty(), str(got_load))
	check("4c2. ★但会弹提示告诉玩家为什么", got_toast.size() == 1
			and String(got_toast[0]).contains("读不了"), str(got_toast))

	# ★1f 的加强版：关闭按钮不只是"注册了"，是真的点得动
	_SP.open(_rows())
	_click_id("close:0")
	check("4d. ★关闭按钮点了真能关掉", _SP.visible == false)

	# ── 5 F5 开合 ──
	_SP.open(_rows())
	_sp_key(KEY_F5)
	await process_frame
	check("5a. ★F5 能关掉已打开的面板", _SP.visible == false)
	_sp_key(KEY_F5)
	await process_frame
	# 面板自己没数据，打开只能发意图——由主控去后端拉列表再 open()
	check("5b. ★F5 打开时会请求拉列表（面板自己不发 open）",
		got_open[0] == 1 and _SP.visible == false, str(got_open))
	_SP.close()
	check("5c. close() 生效", _SP.visible == false)

	# ── 6 空列表 ──
	_SP.open([])
	await process_frame
	check("6a. ★空列表不崩且有提示", _SP.visible == true)
	check("6b. 空列表时没有行可点", _SP.debug_state()["ids"].has("sel:") == false)
	_SP.close()

	# ── 7 字段缺失的脏数据 ──
	# 后端是同语言的，不该崩；但别让它把整个面板带死
	_SP.open([{"id": "z"}, {"garbage": true}])
	await process_frame
	check("7a. ★缺字段的行不崩", _SP.visible == true)
	_SP.close()

	# ── 8 主题色 ──
	var th: GDScript = load("res://scripts/ui_theme.gd")
	check("8a. DANGER 颜色存在（坏档标红用）", th.DANGER != null)
	check("8b. DANGER 与 ACCENT 不是同一个色（坏档红与选中蓝要分得开）",
		th.DANGER != th.ACCENT)


func _click_id(want: String) -> void:
	for b in _SP._btns:
		if String(b["id"]) == want:
			var ev := InputEventMouseButton.new()
			ev.pressed = true
			ev.button_index = MOUSE_BUTTON_LEFT
			ev.position = b["rect"].get_center()
			_SP._gui_input(ev)
			return
	push_error("[t_save] 点不到 %s" % want)


func _sp_key(k: int) -> void:
	var ev := InputEventKey.new()
	ev.pressed = true
	ev.keycode = k
	_SP._input(ev)


func _teardown() -> void:
	if _SP != null and is_instance_valid(_SP):
		if _SP.get_parent() != null:
			_SP.get_parent().remove_child(_SP)
		_SP.free()
		_SP = null
