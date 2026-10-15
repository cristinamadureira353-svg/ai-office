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
	var client := ClientPanel.new()
	var chat := ChatPanel.new()
	host.add_child(employee)
	host.add_child(client)
	host.add_child(chat)
	var chats: Array = []
	var sent: Array = []
	var feedback: Array = []
	var commands: Array = []
	employee.chat_requested.connect(func(who):
		chats.append(who)
		chat.open_with(who))
	chat.send_requested.connect(func(who, text): sent.append([who, text]))
	client.feedback.connect(func(message): feedback.append(message))
	client.cmd_requested.connect(func(who, action, arg): commands.append([who, action, arg]))
	await process_frame
	employee.update_from({"workers":staff})
	client.show_client({"id":"input", "status":"服务中", "task":"测试需求", "served_by":"flash"}, staff)
	for i in 3:
		await process_frame
	await click(employee._bars[0].rect.get_center())
	check("客户详情可见时仍能点击底部员工卡", employee.selected == "m3")
	for i in 5:
		client.show_client({"id":"input", "status":"服务中", "task":"测试需求"}, staff)
		await process_frame
		await click(employee._bars[i].rect.position + Vector2(22, 36))
		check("客户详情打开时选中员工 " + staff[i].id, employee.selected == staff[i].id)
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
	staff[0].brain_down = true
	staff[1].off_today = true
	staff[2].job = "another-job"
	staff[3].stamina = 10
	staff[4].strike = true
	client.show_client({"id":"blocked", "status":"等待", "task":"测试需求"}, staff)
	for i in 3:
		await process_frame
	for button in client._disabled_btns:
		await click(button.rect.get_center())
	check("五种无法派单的原因均有反馈", feedback.size() == 5 and feedback[0].contains("脑袋宕机") and feedback[1].contains("轮休") and feedback[2].contains("另一单") and feedback[3].contains("体力") and feedback[4].contains("罢工"))
	check("点击禁用按钮不发送派单请求", commands.is_empty())
	check("透明区域允许场景拾取", not client._has_point(Vector2(120, 160)) and not employee._has_point(Vector2(120, 160)))
	check("加大字体后长状态可读", UITheme.fit("脑袋宕机了", 130, ThemeDB.fallback_font, UITheme.SMALL) == "脑袋宕机了")
	var label := Node2D.new()
	root.add_child(label)
	for zoom in [.4, .55, 1.0, 1.4, 2.0]:
		label.scale = Vector2.ONE * zoom
		var pixels := UITheme.world_font_size(label, 13) * UITheme.world_scale(label)
		check("场景标签缩放后保持可读 %s" % zoom, pixels >= 13 and pixels < 13 + zoom + .01)
	print("EMPLOYEE INPUT: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)
