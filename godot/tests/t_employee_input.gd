extends SceneTree
## 走真实 Viewport GUI 分发，复现客户详情覆盖员工卡的点击。

var passed := 0
var failed := 0

func check(label: String, ok: bool) -> void:
	if ok:
		passed += 1
		print("PASS ", label)
	else:
		failed += 1
		print("FAIL ", label)

func click(pos: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = pos
	event.global_position = pos
	event.pressed = true
	Input.parse_input_event(event)
	event = event.duplicate()
	event.pressed = false
	Input.parse_input_event(event)
	await process_frame
	await process_frame

func _init() -> void:
	await process_frame
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.size = Vector2i(1102, 957)
	await process_frame
	var host := Control.new()
	host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(host)
	var staff: Array = []
	for id in ["m3", "flash", "longcat", "kimi", "step5"]:
		staff.append({"id":id, "acting":"在办公区闲逛", "stamina":100, "mood":70})
	var employee := WorkerPanel.new()
	var chat := ChatPanel.new()
	host.add_child(employee)
	host.add_child(chat)
	var chats: Array = []
	var sent: Array = []
	employee.chat_requested.connect(func(who):
		chats.append(who)
		chat.open_with(who))
	chat.send_requested.connect(func(who, text): sent.append([who, text]))
	await process_frame
	employee.update_from({"workers":staff})
	for i in 3:
		await process_frame
	await click(employee._bars[0].rect.get_center())
	check("员工卡可点开详情", employee.selected == "m3")
	for i in 5:
		await click(employee._bars[i].rect.position + Vector2(22, 36))
		check("选中员工 " + staff[i].id, employee.selected == staff[i].id)
		await click(employee._chat_buttons[i].rect.get_center())
		check("直接聊天按钮打开正确员工 " + staff[i].id, chat.visible and chat.who == staff[i].id and chats[-1] == staff[i].id)
		check("打开聊天后可直接输入 " + staff[i].id, chat._entry.has_focus())
		chat.set_draft("测试对话 " + staff[i].id)
		await process_frame
		await click(chat._send_rect.get_center())
		check("点击发送传递正确对象和内容 " + staff[i].id, sent.size() == i + 1 and sent[-1] == [staff[i].id, "测试对话 " + staff[i].id])
		chat.begin_stream()
		chat.set_draft("不应重复提交")
		await click(chat._send_rect.get_center())
		check("等待回复时不会重复发送 " + staff[i].id, sent.size() == i + 1)
		chat.end_stream()
		await click(chat._close_rect.get_center())
		check("鼠标关闭聊天 " + staff[i].id, not chat.visible)
	# ★旧经营玩法已停用：员工详情里不再有「派单」按钮，也就没有"能不能派单"的门槛。
	#   现在详情里只有真 Bot 的指令（休息 / 摸鱼 / 开会 / 轮休 / 回工位 / 聊天）。
	employee.selected = "m3"
	await process_frame
	var ids: Array = []
	for button in employee._btns:
		ids.append(String(button.id))
	check("员工详情只剩氛围指令与聊天，没有派单入口",
			not ids.has("assign") and ids.has("chat") and ids.has("rest"))
	check("透明区域允许场景拾取", not employee._has_point(Vector2(120, 160)))
	check("加大字体后长状态可读", UITheme.fit("脑袋宕机了", 130, ThemeDB.fallback_font, UITheme.SMALL) == "脑袋宕机了")
	var label := Node2D.new()
	root.add_child(label)
	for zoom in [.4, .55, 1.0, 1.4, 2.0]:
		label.scale = Vector2.ONE * zoom
		var pixels := UITheme.world_font_size(label, 13) * UITheme.world_scale(label)
		check("场景标签缩放后保持可读 %s" % zoom, pixels >= 13 and pixels < 13 + zoom + .01)
	print("EMPLOYEE INPUT: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)
