extends SceneTree
## 经真实 Viewport 分发验证裁决点击、重复提交保护和失败重试。

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
	root.size = Vector2i(1120, 720)
	await process_frame
	var host := Control.new()
	host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(host)
	var staff := WorkerPanel.new()
	var client := ClientPanel.new()
	var conflict := ConflictUI.new()
	# 与主界面相同的前后顺序，包含后加的聊天、复盘、气泡和结算面板。
	for panel in [staff, client, conflict, BlameUI.new(), ChatPanel.new(), BanterUI.new(), DailyReport.new()]:
		host.add_child(panel)
	await process_frame
	staff.update_from({"workers":[{"id":"m3","mood":70,"stamina":100}]})
	client.show_client({"id":"customer", "status":"服务中", "task":"测试订单"}, [])
	var choices: Array = []
	conflict.judge_pressed.connect(func(id, kind): choices.append([id, kind]))
	for i in 4:
		var id := "conflict-%d" % i
		var data := {"client":id,"a":"m3","b":"flash","task":"跑通流程","lines":[]}
		conflict.show_conflict(data)
		await process_frame
		await process_frame
		var target: Vector2 = conflict._buttons[i].rect.get_center()
		await click(target)
		check("实际鼠标裁决 %d" % i, choices.size() == i + 1 and choices[-1] == [id, ["a","b","reject","scold"][i]])
		check("点击后立刻显示提交状态 %d" % i, conflict.submitting and conflict._message.contains("正在提交"))
		conflict.show_conflict(data.duplicate(true))
		await click(target)
		check("重复快照与重复点击不重复提交 %d" % i, conflict.submitting and choices.size() == i + 1)
		conflict.complete_judgement("old-conflict", false, "旧请求失败")
		check("旧冲突回执不改变当前弹窗 %d" % i, conflict.submitting)
		conflict.complete_judgement(id, true, "完成")
		check("成功后等待状态刷新且不重复提交 %d" % i, conflict.submitting and conflict._message.contains("裁决已完成"))
		conflict.hide_conflict()
		check("后端更新后关闭并清空交互区域 %d" % i, not conflict.visible and conflict._buttons.is_empty())
	var retry := {"client":"retry","a":"m3","b":"flash","task":"失败后重试","lines":[]}
	conflict.show_conflict(retry)
	await process_frame
	await process_frame
	var retry_target: Vector2 = conflict._buttons[0].rect.get_center()
	await click(retry_target)
	conflict.complete_judgement("retry", false, "连接暂时失败，请重试")
	check("失败原因显示在弹窗内并恢复选择", conflict.visible and not conflict.submitting and conflict._message.contains("请重试"))
	await click(retry_target)
	check("失败后能再次裁决同一订单", choices.size() == 6 and choices[-1] == ["retry", "a"])
	conflict.show_conflict({"client":"new","a":"m3","b":"flash","task":"新订单","lines":[]})
	check("新冲突不会继承上一请求的禁用状态", not conflict.submitting and conflict._message.is_empty())
	print("CONFLICT INPUT: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)
