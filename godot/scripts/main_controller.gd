class_name MainController
extends Node2D
## 主控制器：装配场景、角色、HUD，处理玩家输入。
##
## 面板可点了 —— 点角色开指令面板、复盘会显示记录、聊天走 SSE 流式。
##
## ★旧经营玩法（假客户上门 / 抢单冲突 / 每日结算）的三个面板已整体移除：
##   客户不再生成、assign 接单指令被服务端拒绝、冲突与结算都成了死代码。
##   真任务失败改由甩锅机制处理（_poll_blame 读 /api/office/panel）。

const WORKER_SCRIPT := "res://scripts/worker.gd"
## 没有真实 Bot 团队时，办公室保留游戏自带的五个员工。
const DEFAULT_SLOTS := ["m3", "flash", "longcat", "kimi", "step5"]
const POLL_INTERVAL := 0.4
const CELL := 32.0
const PICK_R := 22.0

var office: OfficeView
var hud: GameHUD
var link: BackendLink
var workers: Dictionary = {}      # who -> Worker
var state: Dictionary = {}
## 冷启动从 /api/office/panel 拉到的真 Bot 面板。/api/state 只有在 Bot 引擎
## 已经起来时才带 bot_panel，所以启动时主动叫醒引擎一次。
var _bot_panel: Dictionary = {}
## 面板最多试几次：启动时 1 次；万一启动时后端还没起来，后端连上时再补一次。
## 成功就不再试。全程没有定时轮询。
const PANEL_MAX_ATTEMPTS := 3
var _panel_attempts := 0
var _panel_ok := false

var typing: Node2D = null
var save_panel: Control = null

## 存档/读档结果提示（交由 HUD 显示）
signal notice(msg: String)
## 甩锅发生了（文案已算好）。发信号只是为了让这件事可观测，表现交给 hud.toast。
signal blame_fired(text: String)
var rel_panel: RelationPanel

var worker_panel: WorkerPanel
## Chief 的主管位节点（会议室主桌一头）。
var _chief_desk: ChiefDesk = null
var blame_ui: BlameUI
var chat_panel: ChatPanel
var banter_ui: BanterUI
var sse: SseChat
## 真实 Bot 的回复通道（/api/events）。没有真实 Bot 时它待命，不参与对话。
var bot_sse: BotSse

## ── 甩锅的新燃料：真 Bot 任务失败 ──────────────────────────────────────
## 客户系统整体停用后（接单被拒、客户面板永远是空的），原来的
## 「抢单冲突 → 弹窗甩锅」永远触发不了。改由真任务失败点火：
## 一个 task 从非 failed 跳成 failed 就甩一次锅，锅扣在那个 task 的
## 执行者（bot_id 对应的员工）头上。
## ★关系也得跟着动：甩锅是真事件，关系的燃料不能只剩下文案。
##   这里只报「事件名 + 两个工位 key」，数值由 Python 侧 relations 算，
##   客户端不自己算关系值、也不调模型。

## 两次甩锅之间至少隔这么久（毫秒）。超出的直接丢弃，不排队。
const BLAME_COOLDOWN_MSEC := 3000

## task key -> 上一次快照里见到的 status。每次快照按当前 task 重建，不会无限长。
var _task_status: Dictionary = {}
## 已经甩过锅的 task key。同一个 task 一辈子只甩一次。
var _blamed_tasks: Dictionary = {}
## 甩锅冷却到什么时候（Time.get_ticks_msec()）。0 = 还没甩过，第一击不会被吞。
var _blame_cool_until := 0


func _ready() -> void:
	y_sort_enabled = true

	link = BackendLink.new()
	link.interval = POLL_INTERVAL
	add_child(link)
	link.state_updated.connect(_on_state)
	link.connection_changed.connect(_on_backend_connection)
	link.connection_changed.connect(func(c): print("[MAIN] 后端 %s" % ("已连接" if c else "断开")))

	office = OfficeView.new()
	office.name = "Office"
	add_child(office)

	# M4-2：打字音效。跟着场景走（不是 autoload）——它要按角色世界坐标定位，
	# 生命周期理应和办公室一样。素材与 BGM 那种跨场景常驻的才进 autoload。
	typing = load("res://scripts/typing_audio.gd").new()
	typing.name = "TypingAudio"
	add_child(typing)


	for who in DEFAULT_SLOTS:
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
	hud.chief_requested.connect(func(): _open_chat("chief"))

	rel_panel = RelationPanel.new()
	rel_panel.name = "Relations"
	rel_panel._open = false
	layer.add_child(rel_panel)

	_build_panels(layer)

	# ★冷启动只拉一次办公室面板：服务端 GET /api/office/panel 内部会 ensureBot()，
	#   把懒加载的 Bot 引擎叫醒。引擎起来之后 /api/state 自己就带 bot_panel，
	#   所以这里不轮询，_poll() 一行也没动。
	_pull_office_panel_once()

	# 启动时指定聚焦区域（截图脚本用 SHOT_REGION=lobby/office/meeting）
	var r := OS.get_environment("SHOT_REGION")
	if r != "" and office.cam_dir:
		office.cam_dir.go_to(r)
		office.cam_dir.snap_to(r)
	var z := OS.get_environment("SHOT_ZOOM")
	if z != "" and z.is_valid_float() and office.cam_dir.cam:
		office.cam_dir.cam.zoom = Vector2(float(z), float(z))

	print("[MAIN] 装配完成：%d 个角色 / %d 个面板" % [workers.size(), 7])


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
				save_panel.open_requested.emit()
		elif action == "team":
			_open_team_panel())
	worker_panel.selection_changed.connect(func(who):
		if not who.is_empty():
			hud.toast("已选中 %s · 右侧查看指令，卡片上可直接聊天" % UITheme.name_of(who))
		_refresh_detail_hud())
	layer.add_child(worker_panel)

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

	sse = SseChat.new()
	sse.name = "SseChat"
	add_child(sse)
	chat_panel.closed.connect(func():
		if sse.busy:
			sse.cancel()
			chat_panel.end_stream()
		# 关面板就不再收这个 Bot 的增量，连接一起收掉。
		bot_sse.unwatch())
	sse.started.connect(func(_w): chat_panel.begin_stream())
	sse.delta.connect(func(_w, t): chat_panel.push_delta(t))
	sse.finished.connect(func(_w, ok): chat_panel.end_stream())
	sse.failed.connect(func(_w, msg):
		chat_panel.end_stream()
		hud.toast("对话失败：%s" % msg))
	# 真实 Bot 的回复走 /api/events 长连接：按 chatId 过滤出当前这个 Bot，
	# delta 已经是算好的增量，直接喂给同一个气泡；断线/失败由 dropped 收尾。
	bot_sse = BotSse.new()
	bot_sse.name = "BotSse"
	add_child(bot_sse)
	bot_sse.delta.connect(func(t):
		if chat_panel.visible:
			chat_panel.push_delta(t))
	bot_sse.finished.connect(func(_status):
		chat_panel.end_stream()
		bot_sse.unwatch())
	bot_sse.dropped.connect(func(msg):
		chat_panel.end_stream()
		bot_sse.unwatch()
		hud.toast(msg))
	# 存档是模态窗口，绘制与点击顺序都必须高于员工栏和会议提示。
	layer.move_child(save_panel, layer.get_child_count() - 1)


## 切到 MiniMax Bot 团队面板。跨 iframe 的顶层导航由注入的 host.js 完成。
func _open_team_panel() -> void:
	# 原生客户端没有 /bot 路由，只有 Web 导出才有这个入口。
	if not OS.has_feature("web"):
		hud.toast("这个版本打不开团队面板")
		return
	var host = JavaScriptBridge.get_interface("AIOfficeHost")
	if host == null:
		hud.toast("这个版本打不开团队面板")
		return
	host.open("/bot?from=office")


## 网页版：把和真实 Bot 的对话交给父页面的 HTML 抽屉（876×760，右侧滑出）。
## 父页面没定义 AIOfficeChat（例如直接打开导出的游戏页）就返回 false，
## 调用方据此退回游戏自绘的对话面板。
func _open_host_chat(bot_id: String) -> bool:
	if not OS.has_feature("web"):
		return false
	var host = JavaScriptBridge.get_interface("AIOfficeHost")
	if host == null:
		return false
	var ok: Variant = host.openChat(bot_id)
	return ok is bool and ok


func _open_chat(who: String) -> void:
	for w in state.get("workers", []):
		if str(w.get("id", "")) == who and w.get("brain_down", false):
			chat_panel.close()
			worker_panel.selected = who
			worker_panel.selection_changed.emit(who)
			worker_panel.queue_redraw()
			hud.toast("脑袋宕机了，额度恢复后再重启脑袋")
			return
	# 网页版：这个工位坐着真实 Bot，就把对话交给父页面的 HTML 抽屉——
	# 富文本、表格、文件卡由 Bot 面板渲染，比自绘面板能装得多。
	# 原生版没有 HTML 层，_open_host_chat() 返回 false，继续走下面的自绘面板。
	var bot_id := _bot_id_of_slot(who)
	if not bot_id.is_empty() and _open_host_chat(bot_id):
		if chat_panel.visible:
			chat_panel.close()
		worker_panel.selected = ""
		worker_panel.queue_redraw()
		if save_panel.visible:
			save_panel.close()
		_refresh_detail_hud()
		hud.toast("在和 %s 说话" % ChatPanel.NAMES.get(who, who))
		return
	if sse.busy:
		sse.cancel()
		chat_panel.end_stream()
	# 换人：上一个 Bot 的增量不许再灌进新面板。
	bot_sse.unwatch()
	worker_panel.selected = ""
	worker_panel.queue_redraw()
	if save_panel.visible:
		save_panel.close()
	chat_panel.open_with(who)
	# 这个工位上坐着真实 Bot 才接真通道：先连上 /api/events 备用，
	# 没有 Bot（团队没初始化）就保留原来的假人链路兜底。
	chat_panel.set_real_bot(not bot_id.is_empty())
	if not bot_id.is_empty():
		bot_sse.watch(bot_id)
	_refresh_detail_hud()
	hud.toast("在和 %s 说话" % ChatPanel.NAMES.get(who, who))


func _request_command(who: String, action: String, arg) -> void:
	var name := UITheme.name_of(who)
	var message := "正在发送指令…"
	match action:
		"goto":
			message = "正在安排 %s %s…" % [name, {"desk":"回工位", "lounge":"去休息", "slack":"去摸鱼"}.get(str(arg), "移动")]
		"off": message = "正在安排 %s 今天轮休…" % name
		"back": message = "正在恢复 %s 的排班…" % name
		"meeting": message = "正在召集会议…"
		"dismiss": message = "正在安排散会…"
		"reboot": message = "正在检测 %s 的额度是否恢复…" % name
	hud.toast(message)
	link.send_command(who, action, arg)


## 打回：打开一个只收返工意见的面板。这句话会真的发回 Chief，由它重新派单。
func _open_reject(request_id: String) -> void:
	if sse.busy:
		sse.cancel()
		chat_panel.end_stream()
	worker_panel.selected = ""
	worker_panel.queue_redraw()
	if save_panel.visible:
		save_panel.close()
	chat_panel.open_reject(request_id)
	_refresh_detail_hud()
	hud.toast("写一句返工意见 · 这句话会真的发给 Chief")


func _send_chat(who: String, text: String) -> void:
	# 打回模式：意见交回 Chief，由它决定重派或改派——这是真的返工，不是取消。
	if not chat_panel.reject_request_id.is_empty():
		var request_id := chat_panel.reject_request_id
		chat_panel.reject_request_id = ""
		hud.toast("正在把返工意见交给 Chief…")
		link.api_office_reject(request_id, text, func(ok: bool, msg: String):
			chat_panel.close()
			hud.toast(msg))
		return
	# Chief 不在五个员工的旧模型链路里：它走真实 Bot 派活接口。
	if who == "chief":
		if sse.busy:
			hud.toast("上一句还没说完")
			return
		chat_panel.begin_stream()
		chat_panel.push_delta("收到，正在拆给团队…")
		link.api_office_task(text, func(ok: bool, msg: String):
			chat_panel.push_delta("\n" + msg)
			chat_panel.end_stream()
			hud.toast(msg))
		return
	# 真实 Bot 占着的工位：消息走 POST /api/office/chat，回复从 /api/events 逐字进来。
	var bot_id := _bot_id_of_slot(who)
	if not bot_id.is_empty():
		chat_panel.begin_stream()
		chat_panel.push_delta("正在问它…")
		bot_sse.watch(bot_id)
		link.api_office_chat(bot_id, text, func(ok: bool, msg: String):
			if ok:
				return
			# 压根没发出去：不会有回复帧进来，直接把气泡收尾，别让它一直转。
			chat_panel.end_stream()
			bot_sse.unwatch()
			hud.toast(msg))
		return
	if sse.busy:
		hud.toast("上一句还没说完")
		return
	if not sse.send(who, text):
		hud.toast("发不出去")


## 这个工位上占着的是不是真实 Bot：是就返回它的 bot_id，不是返回空串。
## 和 worker_panel 的 staff 行同源（/api/state 快照里的 bot_panel）。
func _bot_id_of_slot(slot: String) -> String:
	var panel = state.get("bot_panel")
	if not (panel is Dictionary) or not bool(panel.get("ready", false)):
		return ""
	# Chief 是主管，不占工位，所以不在 staff 里——它的 id 单独挂在 panel.chief。
	# 漏了这条，「对 Chief 说」会退回自绘面板，看起来像没更新。
	if slot == "chief":
		var chief: Dictionary = UITheme.dict_of(panel, "chief")
		return UITheme.str_of(chief, "bot_id")
	for member in panel.get("staff", []):
		if member is Dictionary and String(member.get("slot", "")) == slot:
			return String(member.get("bot_id", ""))
	return ""

## 站会板的三行：谁在干什么 / 谁卡住了 / 还剩几单。
## 只读 bot_panel（和员工面板、HUD 看板同一份快照），不另造任务真源、不发请求。
func _standup_lines(d: Dictionary) -> Array:
	var panel: Dictionary = UITheme.dict_of(d, "bot_panel")
	var staff: Array = UITheme.arr_of(panel, "staff")
	if not bool(panel.get("ready", false)) or staff.is_empty():
		return ["还没有 Bot 团队", "—", "—"]
	var batches: Array = UITheme.arr_of(panel, "batches")
	# 谁在干什么：在跑的成员 + 他手上那单的标题（取法和 HUD 看板一致）。
	var doing: Array = []
	for member in staff:
		if not (member is Dictionary):
			continue
		if UITheme.str_of(member, "status") != "running":
			continue
		var who := _staff_label(member)
		var title := _current_task_title(batches, UITheme.str_of(member, "bot_id"))
		doing.append(who if title.is_empty() else who + "·" + title)
	if doing.is_empty():
		# 团队在，但没人接活：板子上也要有一行，不能空着。
		doing.append("没人在干活")
	elif doing.size() > 3:
		var extra := doing.size() - 3
		doing = doing.slice(0, 3)
		doing.append("+%d" % extra)
	# 谁卡住了：failed / error 的成员；没有就明说没人卡住。
	var stuck: Array = []
	for member in staff:
		if member is Dictionary and UITheme.str_of(member, "status") in ["failed", "error"]:
			stuck.append(_staff_label(member) + "·失败")
	# 还剩几单：没进 done/failed/cancelled 的任务都还算在头上。
	var left := 0
	for batch in batches:
		if not (batch is Dictionary):
			continue
		for task in batch.get("tasks", []):
			if task is Dictionary and not (UITheme.str_of(task, "status") in ["done", "failed", "cancelled"]):
				left += 1
	var stuck_line := "没人卡住"
	if not stuck.is_empty():
		stuck_line = _join_labels(stuck)
	return [_join_labels(doing), stuck_line, "还剩 %d 单" % left]


func _join_labels(parts: Array) -> String:
	var s := ""
	for i in parts.size():
		if i > 0:
			s += " / "
		s += String(parts[i])
	return s


## 板上的人名：优先 Bot 名（「前端」这种），退化到 role / slot / bot_id。
func _staff_label(member: Dictionary) -> String:
	for key in ["name", "role", "slot", "bot_id"]:
		var v := UITheme.str_of(member, key)
		if not v.is_empty():
			return v
	return "Bot"


## 这个 Bot 手上那单的标题：从最近一批往回找，和 HUD 看板同一取法。
func _current_task_title(batches: Array, bot_id: String) -> String:
	if bot_id.is_empty():
		return ""
	for i in range(batches.size() - 1, -1, -1):
		var batch = batches[i]
		if not (batch is Dictionary):
			continue
		for task in batch.get("tasks", []):
			if task is Dictionary and UITheme.str_of(task, "bot_id") == bot_id:
				return UITheme.str_of(task, "title")
	return ""


## 扫这批 task，挑出「刚刚失败」的：上一次不是 failed、这一次是 failed。
## 启动后第一次拿到 state 时，每个 task 都是第一次见 —— 只建基线，不算跳变，
## 否则一进游戏就满屏甩锅。
func _newly_failed_tasks(panel: Dictionary) -> Array:
	var hits: Array = []
	var now: Dictionary = {}
	for batch in UITheme.arr_of(panel, "batches"):
		if not (batch is Dictionary):
			continue
		for task in batch.get("tasks", []):
			if not (task is Dictionary):
				continue
			var key := _task_key(task)
			if key.is_empty():
				continue
			var st := UITheme.str_of(task, "status")
			now[key] = st
			if not _task_status.has(key):
				continue                    # 第一次见：只记基线，不触发
			if st != "failed":
				continue                    # 只有 failed 算，cancelled/unknown/done 都不算
			if String(_task_status[key]) == "failed":
				continue                    # 一直在 failed 上刷新，不重复触发
			if _blamed_tasks.has(key):
				continue                    # 同一个 task 只甩一次
			hits.append({"key": key, "bot_id": UITheme.str_of(task, "bot_id"),
					"title": UITheme.str_of(task, "title")})
	# 基线整本换成这一批：消失的 task 下次再出现算第一次见，字典也不会无限长。
	_task_status = now
	return hits


## task 的稳定键：优先 request_id（一个任务一个号），退化到 bot_id + 标题。
func _task_key(task: Dictionary) -> String:
	var rid := UITheme.str_of(task, "request_id")
	if not rid.is_empty():
		return rid
	var who := UITheme.str_of(task, "bot_id")
	var title := UITheme.str_of(task, "title")
	if who.is_empty() and title.is_empty():
		return ""
	return who + "|" + title


## 甩一次锅。同一时刻最多播一条；冷却期内多出来的直接丢弃，不排队。
func _poll_blame(d: Dictionary) -> void:
	var panel: Dictionary = UITheme.dict_of(d, "bot_panel")
	var hits := _newly_failed_tasks(panel)
	if hits.is_empty():
		return
	# 这一批跳变全部登记：每个 task 一辈子只裁决一次，哪怕这次不播。
	for hit in hits:
		_blamed_tasks[String(hit.get("key"))] = true
	if Time.get_ticks_msec() < _blame_cool_until:
		return
	var line := _blame_line(panel, hits[0])
	if line.is_empty():
		return
	_blame_cool_until = Time.get_ticks_msec() + BLAME_COOLDOWN_MSEC
	blame_fired.emit(line)
	if hud:
		hud.toast(line)


## 锅落在那个失败任务的执行者头上，顺手拉一个同事垫背。
## 文案在这里出，关系变化同时记一笔（数值在 Python 侧算）。
func _blame_line(panel: Dictionary, hit: Dictionary) -> String:
	var culprit_bot := UITheme.str_of(hit, "bot_id")
	var scapegoat := _random_scapegoat(panel, culprit_bot)
	if scapegoat.is_empty():
		return ""            # 团队只有一个人：没人可垫背，这一击不播
	# 甩锅是真的发生 ⇒ 关系也得动：谁被指责、谁把锅甩出去的，两边都记一笔。
	_push_blame_relation(panel, culprit_bot, scapegoat)
	return "%s 把「%s」搞砸了，锅甩给了 %s" % [
			_staff_name_of(panel, culprit_bot), UITheme.str_of(hit, "title"),
			_staff_label(scapegoat)]


## bot_id 对应的员工名；快照里找不到就退回 bot_id 本身。
func _staff_name_of(panel: Dictionary, bot_id: String) -> String:
	for member in UITheme.arr_of(panel, "staff"):
		if member is Dictionary and UITheme.str_of(member, "bot_id") == bot_id:
			return _staff_label(member)
	return bot_id


## 随机拉一个同事垫背（不含闯祸的那个）。随机数只影响文案，不影响任何数值。
## 返回 staff 那一行本身：文案要它的名字，关系事件要它的 bot_id 和工位。
func _random_scapegoat(panel: Dictionary, culprit_bot: String) -> Dictionary:
	var pool: Array = []
	for member in UITheme.arr_of(panel, "staff"):
		if member is Dictionary and UITheme.str_of(member, "bot_id") != culprit_bot:
			pool.append(member)
	if pool.is_empty():
		return {}
	var pick: Dictionary = pool[randi() % pool.size()]
	return pick


## bot_id 对应的工位 key（m3/flash/…）。
## 关系网认的是工位 key —— 真 Bot 坐上工位就自动接进同一张关系网，
## 关系两端不用改成 Bot 名字。找不到就返回空串。
func _slot_of_bot(panel: Dictionary, bot_id: String) -> String:
	if bot_id.is_empty():
		return ""
	for member in UITheme.arr_of(panel, "staff"):
		if member is Dictionary and UITheme.str_of(member, "bot_id") == bot_id:
			return UITheme.str_of(member, "slot")
	return ""


## 甩锅落地成关系变化：
##   被指责的人（背锅的同事）对甩锅的人 -4  → blame_accused
##   甩锅的人对被指责的人 +1              → blame_shift
## 数值全在 relations.EVENT_DELTAS 里，这里只报事件名和两个工位 key，
## 具体数值由 Python 侧算（客户端不自己算关系值）。
## 发不出去就算了：这是氛围功能，不能影响游戏。
func _push_blame_relation(panel: Dictionary, culprit_bot: String, scapegoat: Dictionary) -> void:
	var accused_slot := _slot_of_bot(panel, UITheme.str_of(scapegoat, "bot_id"))
	var sharker_slot := _slot_of_bot(panel, culprit_bot)
	if accused_slot.is_empty() or sharker_slot.is_empty() or accused_slot == sharker_slot:
		return
	_send_rel_event("blame_accused", accused_slot, sharker_slot, true)
	_send_rel_event("blame_shift", sharker_slot, accused_slot, true)


## 关系事件：纯数值，不调模型。who 传甩锅的人——这件事是他干的。
## quiet=true：关系照样发给 Python 侧（关系是真的变），只是不再单独弹一条 toast。
## 甩锅一次只该有一条提示，关系八卦是它的燃料，不是第二条提示。
func _send_rel_event(event: String, a: String, b: String, quiet: bool = false) -> void:
	if link == null:
		return
	link.send_command(b, "rel_event", {"event": event, "a": a, "b": b},
			true, "", quiet)


## 当前该出现在办公室里的工位：有真实 Bot 团队时只留团队占的工位，
## 否则保留游戏自带的五个员工。
func _expected_slots(d: Dictionary) -> Array:
	var panel = d.get("bot_panel")
	if panel is Dictionary and bool(panel.get("ready", false)):
		var staff: Array = panel.get("staff", [])
		if not staff.is_empty():
			var slots: Array = []
			for member in staff:
				var slot := String(member.get("slot", ""))
				if not slot.is_empty() and not slots.has(slot):
					slots.append(slot)
			return slots
	return DEFAULT_SLOTS


## 员工节点跟着工位集合走：多出来的收掉，少的补上。
## 小人按工位取贴图，所以谁坐哪张椅子和 Bot 的名字是解耦的。
func _sync_workers(slots: Array) -> void:
	if office == null:
		return
	for slot in workers.keys():
		if slots.has(slot):
			continue
		var node: Worker = workers[slot]
		workers.erase(slot)
		if is_instance_valid(node):
			node.queue_free()
	for slot in slots:
		if workers.has(slot):
			continue
		var w := office.spawn_worker(slot, WORKER_SCRIPT)
		if w:
			workers[slot] = w


## Chief 的主管位：会议室主桌一头。找不到干净位置就退回员工面板的只读条目。
func _sync_chief_desk(d: Dictionary) -> void:
	var panel = d.get("bot_panel")
	var chief: Dictionary = {}
	if panel is Dictionary and bool(panel.get("ready", false)):
		chief = UITheme.dict_of(panel, "chief")
	if chief.is_empty():
		if _chief_desk != null and is_instance_valid(_chief_desk):
			_chief_desk.queue_free()
		_chief_desk = null
		if worker_panel:
			worker_panel.chief_fallback = false
		return
	if _chief_desk == null or not is_instance_valid(_chief_desk):
		var spot := office.chief_spot()
		if spot.x < 0:
			# 找不到干净位置：主管位只出现在员工面板里，不占工位行。
			worker_panel.chief_fallback = true
			worker_panel.chief_entry = chief
			worker_panel.queue_redraw()
			return
		_chief_desk = ChiefDesk.new()
		_chief_desk.name = "ChiefDesk"
		_chief_desk.position = Vector2(spot) * 32.0
		office.unit_layer.add_child(_chief_desk)
	worker_panel.chief_fallback = false
	worker_panel.chief_entry = chief
	_chief_desk.title = String(chief.get("name", "Chief"))
	_chief_desk.subtitle = String(chief.get("role", "总管"))
	_chief_desk.queue_redraw()


## 冷启动拉一次办公室面板。只在这里拉，_poll() 一行没动，也没有第二个轮询循环。
## 成功就把真面板塞进 state：HUD 看板、员工面板、办公室工位都从这一份读。
## 失败就安静降级——游戏照常玩，先显示游戏自带的五个员工。
func _pull_office_panel_once() -> void:
	if _panel_ok or _panel_attempts >= PANEL_MAX_ATTEMPTS:
		return
	_panel_attempts += 1
	link.api_office_panel(func(ok: bool, panel: Dictionary):
		if not ok or panel.is_empty():
			return
		_panel_ok = true
		_apply_bot_panel(panel))


## 后端从断开变连上时，如果面板还没拿到（多半是游戏比后端先启动），
## 就再拉一次。仍然不是轮询：只在连接状态翻转的那一刻试一次。
func _on_backend_connection(is_connected: bool) -> void:
	if not is_connected:
		return
	_pull_office_panel_once()


## 把真面板塞进各处快照，并立刻重绘。
func _apply_bot_panel(panel: Dictionary) -> void:
	_bot_panel = panel
	# 主控自己的快照：聊天找真 Bot（_bot_id_of_slot）从这一份取。
	state["bot_panel"] = panel
	# HUD 有自己那份 state（它自己连着 link.state_updated）：补上并重绘，
	# 顶栏的「在线 / 今日单」和看板立刻显示真团队。
	if hud:
		hud.state["bot_panel"] = panel
		hud.queue_redraw()


func _on_state(d: Dictionary) -> void:
	# /api/state 只有在 Bot 引擎已经起来时才带 bot_panel。冷启动那次面板拉取
	# 已经把引擎叫醒了，所以这一路通常都带；万一这一帧没带，就用刚拉到的
	# 面板就地补上，别让办公室又闪回五个假员工。
	#   d 就是 link.state 那一份字典，就地补 ⇒ HUD 和员工面板拿到的同一个对象
	#   也带着 bot_panel（GDScript 的 Dictionary 是引用类型）。
	if not d.has("bot_panel") and not _bot_panel.is_empty():
		d["bot_panel"] = _bot_panel
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
	# 站会板：白板上那三行团队状态。纯展示，数据就是这份快照里的 bot_panel。
		office.props.set_board(_standup_lines(d))
	if rel_panel:
		rel_panel.update_from(d)
	for p in [worker_panel, banter_ui]:
		if p and p.has_method("update_from"):
			p.update_from(d)

	# 办公室跟着真实 Bot 团队走：工位多寡、主管位都在这里同步。
	_sync_workers(_expected_slots(d))
	_sync_chief_desk(d)

	# 甩锅的新燃料：真任务失败。客户停用后冲突永远不触发，这里接上。
	_poll_blame(d)

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

	# 复盘会（会议提示 / 甩锅复盘）。抢单冲突面板已随旧经营玩法移除。
	var mt: Dictionary = UITheme.dict_of(d, "meeting")
	if not mt.is_empty():
		blame_ui.show_meeting(mt)
	else:
		blame_ui.hide_meeting()


# ── 点击拾取 ────────────────────────────────────────────────────────────────
func _world_at(screen: Vector2) -> Vector2:
	return get_viewport().get_canvas_transform().affine_inverse() * screen


func _pick(screen: Vector2) -> Dictionary:
	var w := _world_at(screen)
	for who in workers:
		var n: Node2D = workers[who]
		if n and n.visual_rect().has_point(w - n.position):
			return {"kind": "worker", "id": who}
	return {}


func _unhandled_input(event: InputEvent) -> void:
	# ── 鼠标点击 ──
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		if hud.day_button.has_point(event.position):
			link.api_newday()
			get_viewport().set_input_as_handled()
			return
		if hud.bot_button.size.x > 0.0 and hud.bot_button.has_point(event.position):
			_open_chat("chief")
			get_viewport().set_input_as_handled()
			return
		# 看板上的「打回」：让玩家写一句返工意见，这句话会真的回到 Chief。
		var reject_id := hud.reject_at(event.position)
		if not reject_id.is_empty():
			_open_reject(reject_id)
			get_viewport().set_input_as_handled()
			return
		var hit := _pick(event.position)
		if hit.get("kind") == "worker":
			worker_panel.select(String(hit["id"]))
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
	if k == KEY_B:
		_open_chat("chief")
		get_viewport().set_input_as_handled()
		return
	if k == KEY_C:
		# 循环切到下一个角色并打开聊天
		var order := ["m3", "flash", "longcat", "kimi", "step5"]
		var cur := order.find(chat_panel.who) if chat_panel.who != "" else -1
		_open_chat(order[(cur + 1) % order.size()])
		return
	if k == KEY_T:
		link.send_command("", "team_build", "")
		# ★经营玩法停用：团建不再扣钱（服务端 team_build 只回心情），
		#   所以不能报一个玩家在界面上根本看不到的金额。
		hud.toast("团建：全员心情 +25")
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


func _refresh_detail_hud() -> void:
	if hud and worker_panel:
		hud.details_open = not worker_panel.selected.is_empty()
		hud.queue_redraw()
		if blame_ui:
			blame_ui.details_open = hud.details_open
			blame_ui.queue_redraw()
