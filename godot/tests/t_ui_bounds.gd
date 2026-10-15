extends SceneTree
## 长交付物必须可读，按钮必须留在框内；Esc 必须关闭当前聊天。

var passed := 0
var failed := 0

func check(label: String, ok: bool) -> void:
	if ok:
		passed += 1
		print("PASS ", label)
	else:
		failed += 1
		print("FAIL ", label)

func _init() -> void:
	await process_frame
	var host := Control.new()
	host.size = Vector2(1280, 720)
	root.add_child(host)
	var client := ClientPanel.new()
	var chat := ChatPanel.new()
	host.add_child(client)
	host.add_child(chat)
	await process_frame
	var long_result := "第一段：完整交付内容应留在可滚动区域里。\n第二段：不能挤走验收按钮。".repeat(24)
	client.show_client({"id":"bounds", "task":"客户需求".repeat(40), "status":"待验收", "result":long_result, "reward":99999999}, [])
	await process_frame
	await process_frame
	var panel_rect := Rect2(client.size.x - ClientPanel.W - 16, 64, ClientPanel.W, ClientPanel.H)
	if client.has_method("_panel_rect"):
		panel_rect = client.call("_panel_rect")
	var inside := true
	for button in client._btns:
		inside = inside and panel_rect.grow(-16).encloses(button.rect)
	check("长交付物的验收按钮留在面板内", inside and client._btns.size() == 2)
	var body := client.get_node_or_null("ClientBody") as RichTextLabel
	check("完整交付物保留在可滚动正文中", body != null and body.text.contains(long_result) and body.scroll_active)
	if body:
		check("正文与验收按钮保持间隔", Rect2(body.position, body.size).end.y + 12 <= client._btns[0].rect.position.y)
	client.show_client({}, [])
	chat.open_with("m3")
	await process_frame
	var escape := InputEventKey.new()
	escape.keycode = KEY_ESCAPE
	escape.pressed = true
	Input.parse_input_event(escape)
	await process_frame
	check("隐藏客户面板不拦截聊天 Esc", not chat.visible)
	chat.open_with("longcat")
	chat.push_user("需要保留完整历史。".repeat(20))
	chat.begin_stream()
	chat.push_delta(long_result)
	chat.end_stream()
	for i in 4:
		await process_frame
	var messages := chat.get_node("ChatMessages") as ScrollContainer
	check("超长聊天可滚动，不会整条消失", messages.get_v_scroll_bar().max_value > messages.size.y)
	check("聊天滚动区被裁切在面板内", messages.clip_contents and chat._panel_rect().grow(-24).encloses(Rect2(messages.position, messages.size)))
	check("输入框与聊天区保持间距", messages.position.y + messages.size.y + 20 <= chat._entry.position.y)
	check("输入框和计数留有底部空间", chat._entry.position.y + chat._entry.size.y + 24 < chat._panel_rect().end.y)
	chat.close()
	var font := ThemeDB.fallback_font
	var widths_ok := true
	for value in ["LongCat", "中文姓名与内容混排 Deliverable", "9999999999999999999 元", long_result]:
		for width in [26, 68, 120, 210]:
			var shown := UITheme.fit(value, width, font, 12)
			widths_ok = widths_ok and font.get_string_size(shown, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x <= width
	check("中英长名字和长数字都按像素留在列内", widths_ok)
	check("正文保留手动换行", UITheme.wrap("第一行\n第二行", 210, font, 12) == ["第一行", "第二行"])
	var staff: Array = []
	for id in ["m3", "flash", "longcat", "kimi", "step5"]:
		staff.append({"id":id, "acting":"在茶水间休息", "tag":"很长的角色标签".repeat(8), "blurb":long_result, "stamina":100, "mood":100, "fatigue":3})
	var worker := WorkerPanel.new()
	var relations := RelationPanel.new()
	host.add_child(worker)
	host.add_child(relations)
	await process_frame
	worker.update_from({"workers":staff})
	for viewport in [Vector2(1120,720), Vector2(1102,957), Vector2(1280,720), Vector2(1600,1000)]:
		host.size = viewport
		worker.size = viewport
		relations.size = viewport
		var detail_inside := true
		for id in ["m3", "flash", "longcat", "kimi", "step5"]:
			worker.selected = id
			worker.queue_redraw()
			await process_frame
			await process_frame
			var frame := worker._panel_rect().grow(-24)
			for button in worker._btns:
				detail_inside = detail_inside and frame.encloses(button.rect)
			detail_inside = detail_inside and frame.encloses(Rect2(worker._sb.position, worker._sb.size))
		check("五名员工详情的状态条和六个按钮均在框内 %s" % viewport, detail_inside)
		var list := worker._list_rect()
		var cards_inside := worker._bars.size() == 5
		for card in worker._bars:
			cards_inside = cards_inside and list.grow(-16).encloses(card.rect)
		check("五张员工卡留在外框内 %s" % viewport, cards_inside)
		var chats_inside := worker._chat_buttons.size() == 5
		for button in worker._chat_buttons:
			chats_inside = chats_inside and list.grow(-16).encloses(button.rect)
		check("五个直接聊天入口留在员工栏内 %s" % viewport, chats_inside)
		check("关系面板完整位于员工栏上方 %s" % viewport, relations._panel_rect().end.y + 16 <= list.position.y)
	worker.selected = ""
	var save := SavePanel.new()
	host.add_child(save)
	await process_frame
	var saves: Array = []
	for i in 12:
		saves.append({"id":str(i), "ok":true, "name":long_result, "why":long_result, "money":999999999})
	save.open(saves)
	await process_frame
	await process_frame
	var wheel := InputEventMouseButton.new()
	wheel.pressed = true
	wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
	wheel.position = save._list_rect.get_center()
	save._gui_input(wheel)
	check("存档滚轮能显示后面的条目", save._scroll_index == 1 and save._btns[0].who == "1")
	var save_inside := true
	for button in save._btns:
		save_inside = save_inside and save._panel_rect().grow(-16).encloses(button.rect)
	check("长存档列表和操作按钮都留在框内", save_inside)
	save.close()
	var conflict := ConflictUI.new()
	host.add_child(conflict)
	await process_frame
	conflict.show_conflict({"client":"test", "a":"longcat", "b":"step5", "task":long_result, "lines":[]})
	await process_frame
	await process_frame
	var judgements: Array = []
	conflict.judge_pressed.connect(func(id, kind): judgements.append([id, kind]))
	for button in conflict._buttons:
		var click := InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_LEFT
		click.pressed = true
		click.position = button.rect.get_center()
		conflict._gui_input(click)
		conflict.complete_judgement("test", false, "模拟重试")
	check("裁决按钮布局调整后仍发出对应选择", judgements == [["test","a"],["test","b"],["test","reject"],["test","scold"]])
	print("UI BOUNDS: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)
