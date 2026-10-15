class_name MainController
extends Node2D
## 主控制器：装配场景、角色、客户、HUD，处理玩家输入。
##
## M2-9 起：面板全部可点了 —— 点角色开指令面板、点客户开客户面板、
## 抢单冲突弹裁决、复盘会显示记录、聊天走 SSE 流式、跨天弹结算。

const WORKER_SCRIPT := "res://scripts/worker.gd"
const CLIENT_SCRIPT := "res://scripts/client_node.gd"
const POLL_INTERVAL := 0.4
const CELL := 32.0
const PICK_R := 22.0

var office: OfficeView
var hud: GameHUD
var link: BackendLink
var workers: Dictionary = {}      # who -> Worker
var clients: Dictionary = {}      # cid -> ClientNode
var state: Dictionary = {}
var typing: Node2D = null
var save_panel: Control = null

## 存档/读档结果提示（交由 HUD 显示）
signal notice(msg: String)
var rel_panel: RelationPanel
var _seen_clients := {}

var worker_panel: WorkerPanel
var client_panel: ClientPanel
var conflict_ui: ConflictUI
var blame_ui: BlameUI
var chat_panel: ChatPanel
var banter_ui: BanterUI
var daily: DailyReport
var sse: SseChat


func _ready() -> void:
	y_sort_enabled = true

	link = BackendLink.new()
	link.interval = POLL_INTERVAL
	add_child(link)
	link.state_updated.connect(_on_state)
	link.connection_changed.connect(func(c): print("[MAIN] 后端 %s" % ("已连接" if c else "断开")))

	office = OfficeView.new()
	office.name = "Office"
	add_child(office)

	# M4-2：打字音效。跟着场景走（不是 autoload）——它要按角色世界坐标定位，
	# 生命周期理应和办公室一样。素材与 BGM 那种跨场景常驻的才进 autoload。
	typing = load("res://scripts/typing_audio.gd").new()
	typing.name = "TypingAudio"
	add_child(typing)


	for who in ["m3", "flash", "longcat", "kimi", "step5"]:
		var w := office.spawn_worker(who, WORKER_SCRIPT)
		if w:
			workers[who] = w

	var layer := CanvasLayer.new()
	layer.name = "UILayer"
	add_child(layer)

	hud = GameHUD.new()
	hud.name = "HUD"
	hud.link = link
	layer.add_child(hud)
	link.command_done.connect(func(_ok, msg): hud.toast(msg))

	rel_panel = RelationPanel.new()
	rel_panel.name = "Relations"
	rel_panel._open = false
	layer.add_child(rel_panel)

	_build_panels(layer)

	# 启动时指定聚焦区域（截图脚本用 SHOT_REGION=lobby/office/meeting）
	var r := OS.get_environment("SHOT_REGION")
	if r != "" and office.cam_dir:
		office.cam_dir.go_to(r)
		office.cam_dir.snap_to(r)
	var z := OS.get_environment("SHOT_ZOOM")
	if z != "" and z.is_valid_float() and office.cam_dir.cam:
		office.cam_dir.cam.zoom = Vector2(float(z), float(z))

	print("[MAIN] 装配完成：%d 个角色 / %d 个面板" % [workers.size(), 8])


func _build_panels(layer: CanvasLayer) -> void:

	# M4-3：存档面板。F5 开合，面板自己管点击，这里只做接线。
	save_panel = load("res://scripts/save_ui.gd").new()
	save_panel.name = "SavePanel"
	layer.add_child(save_panel)
	save_panel.save_requested.connect(func(n): link.api_save(n))
	save_panel.load_requested.connect(func(i): link.api_load(i))
	# ★拉列表 ≠ 显示。启动时那次 api_saves() 回来只灌数据，
	#   否则存档面板会在游戏一启动就盖住半个画面（实测截图证实）。
	link.saves_loaded.connect(func(lst):
		if save_panel.visible:
			save_panel.open(lst)      # 已经开着才刷新
		else:
			save_panel.set_list(lst))
	save_panel.open_requested.connect(func():
		if chat_panel:
			chat_panel.close()
		if worker_panel:
			worker_panel.selected = ""
			worker_panel.queue_redraw()
		if client_panel:
			client_panel.show_client({}, state.get("workers", []))
		_refresh_detail_hud()
		save_panel.open(save_panel.saves)
		link.api_saves())
	link.save_done.connect(func(ok, msg):
		notice.emit(msg)
		if ok:
			link.api_saves())          # 存完刷新列表
		# 读档成功的提示由后端重启主循环后的下一次状态推送体现
	link.api_saves()

	worker_panel = WorkerPanel.new()
	worker_panel.name = "WorkerPanel"
	worker_panel.cmd_requested.connect(_request_command)
	worker_panel.chat_requested.connect(_open_chat)
	worker_panel.feedback.connect(hud.toast)
	worker_panel.utility_requested.connect(func(action):
		if action == "relations":
			rel_panel.toggle()
		elif action == "save":
			if save_panel.visible:
				save_panel.close()
			else:
				save_panel.open_requested.emit())
	worker_panel.selection_changed.connect(func(who):
		if client_panel:
			client_panel.show_client({}, state.get("workers", []))
		if not who.is_empty():
			hud.toast("已选中 %s · 右侧查看指令，卡片上可直接聊天" % UITheme.name_of(who))
		_refresh_detail_hud())
	layer.add_child(worker_panel)

	client_panel = ClientPanel.new()
	client_panel.name = "ClientPanel"
	client_panel.visibility_changed.connect(_refresh_detail_hud)
	client_panel.cmd_requested.connect(_request_command)
	client_panel.feedback.connect(hud.toast)
	client_panel.accept_requested.connect(
		func(cid, ok): link.send_command("", "accept", cid, ok))
	layer.add_child(client_panel)

	conflict_ui = ConflictUI.new()
	conflict_ui.name = "ConflictUI"
	conflict_ui.judge_pressed.connect(
		func(cid, kind): link.send_command("", "judge", cid, true, kind))
	link.judgement_done.connect(conflict_ui.complete_judgement)
	layer.add_child(conflict_ui)

	blame_ui = BlameUI.new()
	blame_ui.name = "BlameUI"
	layer.add_child(blame_ui)

	chat_panel = ChatPanel.new()
	chat_panel.name = "ChatPanel"
	chat_panel.send_requested.connect(_send_chat)
	layer.add_child(chat_panel)

	banter_ui = BanterUI.new()
	banter_ui.name = "BanterUI"
	layer.add_child(banter_ui)

	daily = DailyReport.new()
	daily.name = "DailyReport"
	layer.add_child(daily)

	sse = SseChat.new()
	sse.name = "SseChat"
	add_child(sse)
	chat_panel.closed.connect(func():
		if sse.busy:
			sse.cancel()
			chat_panel.end_stream())
	sse.started.connect(func(_w): chat_panel.begin_stream())
	sse.delta.connect(func(_w, t): chat_panel.push_delta(t))
	sse.finished.connect(func(_w, ok): chat_panel.end_stream())
	sse.failed.connect(func(_w, msg):
		chat_panel.end_stream()
		hud.toast("对话失败：%s" % msg))
	# 存档是模态窗口，绘制与点击顺序都必须高于员工栏和会议提示。
	layer.move_child(save_panel, layer.get_child_count() - 1)


func _open_chat(who: String) -> void:
	for w in state.get("workers", []):
		if str(w.get("id", "")) == who and w.get("brain_down", false):
			chat_panel.close()
			worker_panel.selected = who
			worker_panel.selection_changed.emit(who)
			worker_panel.queue_redraw()
			hud.toast("脑袋宕机了，额度恢复后再重启脑袋")
			return
	if sse.busy:
		sse.cancel()
		chat_panel.end_stream()
	worker_panel.selected = ""
	worker_panel.queue_redraw()
	client_panel.show_client({}, state.get("workers", []))
	if save_panel.visible:
		save_panel.close()
	chat_panel.open_with(who)
	_refresh_detail_hud()
	hud.toast("在和 %s 说话" % ChatPanel.NAMES.get(who, who))


func _request_command(who: String, action: String, arg) -> void:
	var name := UITheme.name_of(who)
	var message := "正在发送指令…"
	match action:
		"goto":
			message = "正在安排 %s %s…" % [name, {"desk":"回工位", "lounge":"去休息", "slack":"去摸鱼"}.get(str(arg), "移动")]
		"assign": message = "正在安排 %s 接单…" % name
		"off": message = "正在安排 %s 今天轮休…" % name
		"back": message = "正在恢复 %s 的排班…" % name
		"meeting": message = "正在召集会议…"
		"dismiss": message = "正在安排散会…"
		"reboot": message = "正在检测 %s 的额度是否恢复…" % name
	hud.toast(message)
	link.send_command(who, action, arg)


func _send_chat(who: String, text: String) -> void:
	if sse.busy:
		hud.toast("上一句还没说完")
		return
	if not sse.send(who, text):
		hud.toast("发不出去")


func _on_state(d: Dictionary) -> void:
	state = d
	if chat_panel and chat_panel.visible:
		for w in d.get("workers", []):
			if str(w.get("id", "")) == chat_panel.who:
				chat_panel.set_model_down(bool(w.get("brain_down", false)))
				if w.get("brain_down", false) and sse.busy:
					sse.cancel()
					chat_panel.end_stream()
	# ★M4-2：每次快照都喂给打字音——位置、是否在打字、模型当前吐字速度。
	#   BackendLink 已按快照去重，同一 tick 的宕机和恢复也要立即显示。
	if typing:
		var audio_state := d.duplicate(true)
		for w in audio_state.get("workers", []):
			if w.get("brain_down", false):
				w["typing"] = false
				w["type_cps"] = 0.0
			w["x"] = float(w.get("x", 0)) * CELL
			w["y"] = float(w.get("y", 0)) * CELL
		typing.sync(audio_state)
	if office and office.props:
		office.update_props(d)
	if rel_panel:
		rel_panel.update_from(d)
	for p in [worker_panel, client_panel, banter_ui, daily]:
		if p and p.has_method("update_from"):
			p.update_from(d)

	# 角色
	for w in d.get("workers", []):
		var who := String(w.get("id", ""))
		var node: Worker = workers.get(who)
		if node == null or node.md == null:
			continue
		node.set_data(w)
		node.speed = float(w.get("speed", 2.2))
		node.speed_mul = 1.0
		var tgt := link.grid_of(w)
		var route: Array = w.get("path", [])
		if not route.is_empty():
			var end: Array = route[-1]
			tgt = Vector2i(int(end[0]), int(end[1]))
		var cur := node.grid_pos()
		if tgt != cur and (not node.moving or node.target != Vector2(tgt) * CELL):
			var p := Pathfinding.find_path(node.md, cur, tgt)
			if not p.is_empty():
				node.set_path(p, tgt)

	# 客户
	for c in d.get("clients", []):
		_sync_client(c)

	# 清理已消失的客户
	var alive := {}
	for c in d.get("clients", []):
		alive[c.get("id")] = true
	for cid in clients.keys():
		if not alive.has(cid):
			var n: ClientNode = clients[cid]
			if is_instance_valid(n):
				n.begin_exit()
			clients.erase(cid)

	# 冲突 / 复盘会
	var cfs: Array = d.get("conflicts", [])
	if not cfs.is_empty():
		conflict_ui.show_conflict(cfs[0])
	else:
		conflict_ui.hide_conflict()
	var mt: Dictionary = UITheme.dict_of(d, "meeting")
	if not mt.is_empty():
		blame_ui.show_meeting(mt)
	else:
		blame_ui.hide_meeting()

	# 选中的客户要跟着最新状态刷新（它在推进）
	if client_panel.visible:
		var found := false
		for c in d.get("clients", []):
			if String(c.get("id", "")) == String(client_panel.client.get("id", "")):
				found = true
				client_panel.show_client({} if c.get("status") in ["已完成", "已流失", "已放弃"] else c, d.get("workers", []))
				break
		if not found:
			client_panel.show_client({}, d.get("workers", []))


func _sync_client(c: Dictionary) -> void:
	var cid := String(c.get("id", ""))
	if cid.is_empty():
		return
	var st := String(c.get("status", ""))
	if st in ["已完成", "已流失"]:
		if clients.has(cid):
			clients[cid].begin_exit()
			clients.erase(cid)
		return
	var node: ClientNode = clients.get(cid)
	if node == null:
		node = ClientNode.new()
		node.label_slot = clients.size() % 5
		office.client_layer.add_child(node)
		clients[cid] = node
		# ★ 客户刚来：摄像机自动切到大堂，让玩家看见人进门
		if not _seen_clients.has(cid):
			_seen_clients[cid] = true
			office.cam_dir.go_to_client()
		hud.toast("有客户上门了")
	node.setup(c)


# ── 点击拾取 ────────────────────────────────────────────────────────────────
func _world_at(screen: Vector2) -> Vector2:
	return get_viewport().get_canvas_transform().affine_inverse() * screen


func _pick(screen: Vector2) -> Dictionary:
	var w := _world_at(screen)
	for who in workers:
		var n: Node2D = workers[who]
		if n and n.visual_rect().has_point(w - n.position):
			return {"kind": "worker", "id": who}
	for cid in clients:
		var n2: Node2D = clients[cid]
		if n2 and n2.visual_rect().has_point(w - n2.position):
			return {"kind": "client", "id": cid}
	return {}


func _unhandled_input(event: InputEvent) -> void:
	# ── 鼠标点击 ──
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		if hud.day_button.has_point(event.position):
			link.api_newday()
			get_viewport().set_input_as_handled()
			return
		var queued := hud.client_at(event.position) if worker_panel.selected.is_empty() else ""
		if not queued.is_empty():
			for c in state.get("clients", []):
				if str(c.get("id", "")) == queued:
					_show_client(c)
			get_viewport().set_input_as_handled()
			return
		var hit := _pick(event.position)
		if hit.get("kind") == "worker":
			worker_panel.select(String(hit["id"]))
			client_panel.show_client({}, state.get("workers", []))
			get_viewport().set_input_as_handled()
			return
		if hit.get("kind") == "client":
			for c in state.get("clients", []):
				if String(c.get("id", "")) == String(hit["id"]):
					_show_client(c)
			get_viewport().set_input_as_handled()
			return

	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var k := (event as InputEventKey).keycode
	# M4-3：F5 显式转发给存档面板。
	# 不靠 Control 自己收键盘事件——那套依赖焦点，headless 与真机行为不一致，
	# 头less 测试里 `panel._input(ev)` 直接调能过，真机上却可能收不到。
	# 显式转发一次，行为就确定了（面板会 emit open_requested → 上面拉列表 → open）。
	if k == KEY_F5:
		if save_panel:
			save_panel._input(event)
		get_viewport().set_input_as_handled()
		return

	if k == KEY_TAB:
		rel_panel.toggle()
		return
	if k == KEY_C:
		# 循环切到下一个角色并打开聊天
		var order := ["m3", "flash", "longcat", "kimi", "step5"]
		var cur := order.find(chat_panel.who) if chat_panel.who != "" else -1
		_open_chat(order[(cur + 1) % order.size()])
		return
	if k == KEY_T:
		link.send_command("", "team_build", "")
		hud.toast("团建：-80 元，全员心情 +25")
		return
	if k == KEY_N:
		link.api_newday()
		return

	# Q E：切换摄像机区域
	if k == KEY_E:
		office.cam_dir.switch_region(1)
		hud.toast("→ " + office.cam_dir.region_name())
		return
	if k == KEY_Q:
		office.cam_dir.switch_region(-1)
		hud.toast("← " + office.cam_dir.region_name())
		return
	if k == KEY_O:
		office.cam_dir.show_overview()
		hud.toast("办公室全景")
		return

	if state.is_empty():
		return

	# 1-5：把第一个等待中的客户派给对应角色
	if k in [KEY_1, KEY_2, KEY_3, KEY_4, KEY_5]:
		var order := ["m3", "flash", "longcat", "kimi", "step5"]
		var who: String = order[k - KEY_1]
		var c: Dictionary = _first_client(["等待"])
		if c.is_empty():
			hud.toast("现在没有等着的客户")
			return
		link.send_command(who, "assign", c.get("id"))
		hud.toast("派 %s 接「%s」" % [who, GameHUD.cut(c.get("task", ""), 12)])
		return

	if k == KEY_SPACE:
		var c2: Dictionary = _first_client(["待验收"])
		if c2.is_empty():
			hud.toast("没有待验收的活")
			return
		link.send_command("", "accept", c2["id"], true)
		hud.toast("验收通过：「%s」" % GameHUD.cut(c2.get("result", ""), 20))
		return

	if k == KEY_R:
		var c3: Dictionary = _first_client(["待验收"])
		if c3.is_empty():
			return
		link.send_command("", "accept", c3["id"], false)
		hud.toast("已打回")
		return

	if k == KEY_G:
		var free_who := ""
		for w in state.get("workers", []):
			if not w.get("job"):
				free_who = String(w.get("id"))
				break
		if free_who:
			link.send_command(free_who, "goto", "lounge")
			hud.toast("%s 去茶水间了" % free_who)
		else:
			hud.toast("大家都忙着")


func _first_client(statuses: Array) -> Dictionary:
	for c in state.get("clients", []):
		if statuses.has(c.get("status")):
			return c
	return {}


func _show_client(c: Dictionary) -> void:
	worker_panel.selected = ""
	worker_panel.queue_redraw()
	client_panel.show_client(c, state.get("workers", []))
	_refresh_detail_hud()


func _refresh_detail_hud() -> void:
	if hud and worker_panel and client_panel:
		hud.details_open = not worker_panel.selected.is_empty() or client_panel.visible
		hud.queue_redraw()
		if blame_ui:
			blame_ui.details_open = hud.details_open
			blame_ui.queue_redraw()
