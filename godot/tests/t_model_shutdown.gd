extends SceneTree
## 宕机后的动作冻结、派单禁用、聊天及状态显示；不会连接真实后端。
var passed := 0
var failed := 0

func check(label: String, good: bool) -> void:
	passed += int(good)
	failed += int(not good)
	print("PASS " if good else "FAIL ", label)

func _init() -> void:
	call_deferred("run")

func run() -> void:
	var md := MapData.load_from()
	for who in ["m3", "flash", "longcat", "kimi", "step5"]:
		var w := Worker.new()
		root.add_child(w)
		w.setup_worker(who, md)
		w.set_process(false)
		w.set_physics_process(false)
		w.set_data({"id":who, "name":who, "acting":"干活中", "typing":true})
		w._process(.2)
		var frame := w.body.texture
		var position_before := w.position
		w.set_data({"id":who, "name":who, "brain_down":true, "acting":"脑袋宕机了"})
		w.set_path([Vector2i(18, 16)], Vector2i(18, 16))
		w._physics_process(2)
		w._process(2)
		check(who + " 宕机后拒绝路径并冻结位置", not w.moving and w.path.is_empty() and w.position == position_before)
		check(who + " 宕机后停止键盘帧并变灰", w.body.texture == frame and w.body.modulate.r < 1)
		check(who + " 常驻显示脑袋宕机了", w.acting_text == "脑袋宕机了" and w.data.brain_down)
		w.set_data({"id":who, "name":who, "acting":"干活中", "typing":true, "brain_down":false})
		w._process(.1)
		check(who + " 恢复后可以重新播放动作", w.body.modulate == Color.WHITE and w.pose == "type_up")
		w.free()
	var chat := ChatPanel.new()
	root.add_child(chat)
	chat.open_with("kimi")
	chat.set_draft("你好")
	chat.set_model_down(true)
	check("宕机聊天输入框禁用且不能提交", not chat.can_send() and not chat._entry.editable)
	var submitted := [false]
	chat.send_requested.connect(func(_who, _text): submitted[0] = true)
	chat._on_submit("你好")
	check("宕机聊天按回车不发请求", not submitted[0])
	chat.set_model_down(false)
	check("恢复后聊天输入可以使用", chat.can_send() and chat._entry.editable)
	chat.free()
	var sb := StatsBar.new()
	root.add_child(sb)
	sb.set_worker({"brain_down":true})
	check("状态条显示完整宕机文案", sb._status_text() == "脑袋宕机了")
	sb.free()
	var sse := SseChat.new()
	root.add_child(sse)
	var failure := [""]
	sse.failed.connect(func(_who, msg): failure[0] = msg)
	sse.busy = true
	sse.who = "kimi"
	sse._feed("data: {\"type\":\"error\",\"message\":\"脑袋宕机了（额度用完了）\"}\n\ndata: {\"type\":\"finish\",\"got_text\":false}\n\n")
	check("SSE 保留宕机提示且结束流", failure[0].contains("脑袋宕机了") and not sse.busy)
	sse.free()
	var host := Control.new()
	host.size = Vector2(1600, 1000)
	root.add_child(host)
	var detail := WorkerPanel.new()
	var client := ClientPanel.new()
	host.add_child(detail)
	host.add_child(client)
	await process_frame
	var workers: Array = [
		{"id":"kimi", "brain_down":true, "brain_checking":false},
		{"id":"longcat", "brain_down":false},
	]
	detail.update_from({"workers":workers})
	detail.selected = "kimi"
	await process_frame
	await process_frame
	check("宕机详情仅保留重启按钮且留在框内", detail._btns.size() == 1 and detail._btns[0].id == "reboot" and detail._panel_rect().grow(-24).encloses(detail._btns[0].rect))
	var commands: Array = []
	detail.cmd_requested.connect(func(who, action, _arg): commands.append([who, action]))
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = detail._btns[0].rect.get_center()
	detail._gui_input(click)
	check("重启按钮发出一次对应角色指令", commands == [["kimi", "reboot"]])
	workers[0].brain_checking = true
	detail.update_from({"workers":workers})
	await process_frame
	await process_frame
	detail._gui_input(click)
	check("恢复检测进行时禁用重复点击", detail._btns.is_empty() and commands.size() == 1)
	client.show_client({"id":"quota", "status":"等待", "task":"做一单"}, workers)
	await process_frame
	await process_frame
	check("客户派单排除宕机员工并保留正常员工", client._btns.size() == 1 and client._btns[0].who == "longcat")
	host.free()
	var link := BackendLink.new()
	root.add_child(link)
	link._timer.stop()
	var updates: Array = []
	link.state_updated.connect(func(d): updates.append(d))
	var live := {"version":1, "tick":7, "workers":[{"id":"kimi", "brain_down":false}]}
	link._on_done(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), JSON.stringify(live).to_utf8_buffer())
	link._on_done(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), JSON.stringify(live).to_utf8_buffer())
	check("完全相同的状态不重复刷新", updates.size() == 1)
	live.workers[0].brain_down = true
	link._on_done(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), JSON.stringify(live).to_utf8_buffer())
	check("同一 tick 内的宕机也立即推送界面", updates.size() == 2 and updates[1].workers[0].brain_down)
	live.workers[0].brain_checking = true
	link._on_done(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), JSON.stringify(live).to_utf8_buffer())
	check("同一 tick 内的恢复检测状态也更新", updates.size() == 3 and updates[2].workers[0].brain_checking)
	link.free()
	print("MODEL SHUTDOWN: %d passed, %d failed" % [passed,failed])
	quit(0 if failed == 0 else 1)
