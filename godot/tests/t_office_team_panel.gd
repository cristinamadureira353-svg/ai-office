extends SceneTree
## 办公室跟着真实 Bot 团队走：工位数量、Bot 名字、模型、空位「待招募」。

var passed := 0
var failed := 0


func check(label: String, ok: bool) -> void:
	if ok:
		passed += 1
		print("PASS ", label)
	else:
		failed += 1
		print("FAIL ", label)


func staff_entry(slot: String, name: String, role: String, model_label: String, status := "idle") -> Dictionary:
	return {"slot": slot, "bot_id": "bot_" + slot, "name": name, "role": role,
		"model": null, "model_label": model_label, "status": status}


func _init() -> void:
	await process_frame
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.size = Vector2i(1280, 720)
	await process_frame
	var host := Control.new()
	host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(host)
	var panel := WorkerPanel.new()
	host.add_child(panel)
	await process_frame

	var game_workers: Array = []
	for id in ["m3", "flash", "longcat", "kimi", "step5"]:
		game_workers.append({"id": id, "acting": "在办公区闲逛", "stamina": 100, "mood": 70})

	# 没有 Bot 面板时，办公室保持原来的五个默认员工。
	panel.update_from({"workers": game_workers})
	await process_frame
	await process_frame
	check("没有 Bot 团队时仍是五个默认员工", panel._bars.size() == 5)
	check("没有 Bot 团队时没有空工位", panel._vacant.is_empty())

	# 有真实团队：三个成员占三个工位，两个工位空着等人。
	var staff: Array = [
		staff_entry("m3", "前端", "前端开发", "跟随宿主默认", "running"),
		staff_entry("flash", "后端", "后端开发", "跟随宿主默认"),
		staff_entry("longcat", "审查", "代码审查", "MiniMax / MiniMax-M3"),
	]
	panel.update_from({
		"workers": game_workers,
		"bot_panel": {
			"ready": true,
			"chief": {"bot_id": "bot_chief", "name": "Chief", "role": "总管"},
			"staff": staff,
			"empty_slots": ["kimi", "step5"],
			"bindings": {"m3": "bot_m3", "flash": "bot_flash", "longcat": "bot_longcat"},
		},
	})
	await process_frame
	await process_frame
	check("工位跟着团队走：三个成员三张卡", panel._bars.size() == 3)
	check("两个空工位显示待招募", panel._vacant.size() == 2)
	var vacant_slots: Array = []
	for row in panel._vacant:
		vacant_slots.append(row.slot)
	vacant_slots.sort()
	check("空工位是没人占的那两个", vacant_slots == ["kimi", "step5"])
	var ids: Array = []
	for row in panel._bars:
		ids.append(String(row.id).replace("row:", ""))
	check("卡片按工位而不是模型名", ids == ["m3", "flash", "longcat"])
	check("详情显示模型（跟随宿主默认）", panel.detail_model_line("m3") == "模型：跟随宿主默认")
	check("详情显示实际模型", panel.detail_model_line("longcat") == "模型：MiniMax / MiniMax-M3")
	check("没有团队时详情没有模型行", panel.detail_model_line("kimi") == "")

	# 点真实 Bot 的卡片，选中的是它的工位。
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = panel._bars[0].rect.get_center()
	event.global_position = event.position
	event.pressed = true
	Input.parse_input_event(event)
	await process_frame
	await process_frame
	check("点真实 Bot 卡片选中它的工位", panel.selected == "m3")

	# 人多于工位时，最后一格显示「+N」。
	var many: Array = []
	for i in 5:
		many.append(staff_entry(["m3", "flash", "longcat", "kimi", "step5"][i], "员工%d" % i, "开发", "跟随宿主默认"))
	panel.update_from({
		"workers": game_workers,
		"bot_panel": {"ready": true, "chief": {"bot_id": "bot_chief", "name": "Chief"},
			"staff": many, "empty_slots": [], "bindings": {}},
	})
	await process_frame
	await process_frame
	check("超过四个成员时只画四张卡", panel._bars.size() == 4)
	check("多出来的人合并成 +N", panel._overflow.size() == 1 and int(panel._overflow[0].extra) == 1)

	# 真实团队在场时，办公室里只保留团队占的工位（没占的桌子不放小人）。
	var main := MainController.new()
	root.add_child(main)
	await process_frame
	main._on_state({
		"workers": game_workers,
		"bot_panel": {
			"ready": true,
			"chief": {"bot_id": "bot_chief", "name": "Chief", "role": "总管"},
			"staff": staff,
			"empty_slots": ["kimi", "step5"],
			"bindings": {"m3": "bot_m3", "flash": "bot_flash", "longcat": "bot_longcat"},
		},
	})
	await process_frame
	await process_frame
	var kept: Array = []
	for who in main.workers.keys():
		kept.append(String(who))
	kept.sort()
	check("办公室只保留真实团队占用的工位", kept == ["flash", "longcat", "m3"])
	var alive := 0
	for child in main.office.unit_layer.get_children():
		if child is Worker:
			alive += 1
	check("办公室里的小人数量等于团队人数", alive == 3)

	# 打回按钮只对「办公室下达的工单」出现：没有工单号的批次不该出现按钮。
	# （GDScript 的 or 是布尔运算符，拿它做空值兜底会得到 "False" 而不是空串。）
	var hud := GameHUD.new()
	hud.size = Vector2(1280, 720)
	root.add_child(hud)
	await process_frame
	var batch := {"batch_id": "batch_1", "request_id": null,
		"tasks": [{"bot_id": "bot_m3", "title": "页面结构", "status": "running"}]}
	hud.state = {
		"bot_panel": {
			"ready": true,
			"staff": [{"slot": "m3", "bot_id": "bot_m3", "name": "前端", "role": "前端开发", "status": "running"}],
			"batches": [batch],
		},
	}
	hud.queue_redraw()
	await process_frame
	await process_frame
	check("没有工单号的批次不显示打回按钮", hud._reject_rects.is_empty())
	batch["request_id"] = "office:abc"
	hud.queue_redraw()
	await process_frame
	await process_frame
	check("办公室下达的批次显示打回按钮", hud._reject_rects.size() == 1)

	print("OFFICE TEAM PANEL: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)
