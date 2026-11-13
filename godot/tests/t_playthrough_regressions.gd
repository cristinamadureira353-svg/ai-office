extends SceneTree

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
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.size = Vector2i(1280, 720)
	await process_frame
	var main := MainController.new()
	root.add_child(main)
	await process_frame
	main.link.set_process(false)
	var staff: Array = []
	for who in ["m3", "flash", "longcat", "kimi", "step5"]:
		staff.append({"id":who, "stamina":100, "mood":70, "acting":"在工位", "job":null})
	main._on_state({"workers":staff, "meeting":{"kind":"normal", "topic":"周会", "seated":[]}})
	main.save_panel.open([{"id":"playthrough", "ok":true, "day":1, "name":"后台测试存档", "money":500, "rep":50}])
	await process_frame
	var layer := main.save_panel.get_parent()
	check("存档弹窗绘制于其他面板之上", main.save_panel.get_index() == layer.get_child_count() - 1)
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	var overlap: Rect2 = main.save_panel._panel_rect().intersection(main.worker_panel._list_rect())
	check("回归点击位于弹窗与员工栏的重叠区域", overlap.has_area())
	click.position = overlap.get_center()
	click.global_position = click.position
	Input.parse_input_event(click)
	click = click.duplicate()
	click.pressed = false
	Input.parse_input_event(click)
	await process_frame
	check("存档弹窗阻止底层员工栏响应", main.worker_panel.selected.is_empty())
	check("点击遮挡区域后存档面板保持可见", main.save_panel.visible)
	main.save_panel.close()
	# 客户/每日结算已从 MainController 整体移除：喂一份不含 clients/daily 键的快照，
	# _on_state 必须照常走完，办公室团队与员工面板不能因缺少客户数据而崩或不渲染。
	main._on_state({"workers":staff, "meeting":{"kind":"normal", "topic":"周会", "seated":[]}})
	await process_frame
	check("无客户数据快照下 _on_state 照常存下员工快照", main.state.get("workers", []).size() == staff.size())
	check("无客户数据快照下办公室团队照常渲染", main.workers.size() == staff.size() and main.workers.values().all(func(n): return is_instance_valid(n)))
	main.office.cam_dir.snap_to("meeting")
	main.office.cam_dir.cam.force_update_scroll()
	await process_frame
	var visible_area: Rect2 = main.office.cam_dir.view_rect()
	var cam: Camera2D = main.office.cam_dir.cam
	var viewport_center := Vector2(root.size) * .5
	for seat in [Vector2(31, 7), Vector2(33, 7), Vector2(35, 7), Vector2(32, 11), Vector2(34, 11)]:
		var head: Vector2 = viewport_center + (seat * 32 + Vector2(0, -48) - cam.position) * cam.zoom
		var feet: Vector2 = viewport_center + (seat * 32 - cam.position) * cam.zoom
		check("会议室特写显示角色完整坐姿 " + str(seat), visible_area.has_point(head) and visible_area.has_point(feet))
	for viewport in [Vector2(1120,720), Vector2(1102,957), Vector2(1280,720), Vector2(1600,1000)]:
		main.blame_ui.size = viewport
		main.worker_panel.size = viewport
		var brief: Rect2 = main.blame_ui._brief_rect()
		check("会议提示不盖住员工卡或工具按钮 " + str(viewport), brief.end.y + 16 <= main.worker_panel._list_rect().position.y and Rect2(Vector2.ZERO, viewport).encloses(brief))
	main.blame_ui.mt = {"kind":"normal", "phase":"seated"}
	check("普通会议提示当前已在进行", main.blame_ui._phase_text() == "会议进行中")
	main.worker_panel.select("step5")
	check("员工详情打开时让出会议提示区域", main.blame_ui.details_open)
	main.worker_panel.select("step5")
	check("员工详情关闭后恢复会议提示", not main.blame_ui.details_open)
	main.queue_free()
	await process_frame
	print("PLAYTHROUGH REGRESSIONS: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)
