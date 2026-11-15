extends SceneTree
## 甩锅机制：真 Bot 任务失败驱动。
##
## ★旧的「两人抢同一单」冲突面板已删除（冲突来自假客户，不会再发生）。
##   甩锅改由真任务失败点火：任务从非 failed 跳成 failed 就甩一次锅。
##
## 这里测三件事：
##   1. 任务从非 failed 跳成 failed 时甩一次锅
##   2. 同一个失败任务不会反复甩（刷新失败态、失败→恢复→再失败都不重复）
##   3. 甩锅文案不再承诺「心情 -6」这种旧经营玩法的数值

var passed := 0
var failed := 0


func check(label: String, ok: bool, detail := "") -> void:
	if ok:
		passed += 1
		print("PASS ", label)
	else:
		failed += 1
		print("FAIL ", label, ("  → " + detail) if detail != "" else "")


func _init() -> void:
	await process_frame
	# 把后端指向一个没人听的端口：甩锅会顺带发一条关系事件，
	# 别让它打到真的开发后端上改动别人的数据。
	OS.set_environment("AI_OFFICE_PORT", "65499")
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.size = Vector2i(1280, 720)
	await process_frame
	var main := MainController.new()
	root.add_child(main)
	await process_frame
	main.link.set_process(false)
	main.link._timer.stop()
	var lines: Array = []
	main.blame_fired.connect(func(text): lines.append(text))
	var staff: Array = []
	for who in ["m3", "flash", "longcat", "kimi", "step5"]:
		staff.append({"id": who, "acting": "在工位", "job": null})
	var panel := {
		"ready": true,
		"staff": [
			{"slot": "m3", "bot_id": "bot-m3", "name": "前端", "status": "idle"},
			{"slot": "flash", "bot_id": "bot-flash", "name": "后端", "status": "idle"},
		],
		"batches": [{"request_id": "req-1", "tasks": [
			{"bot_id": "bot-m3", "title": "实现登录接口", "status": "running"},
		]}],
	}
	# 第一次看到这只任务：只建基线，不甩锅（否则一进游戏就满屏甩锅）。
	main._on_state({"workers": staff, "bot_panel": panel})
	check("第一次看到任务只建基线不甩锅", lines.is_empty(), str(lines))
	# 任务失败：甩一次锅。
	var failed_panel: Dictionary = panel.duplicate(true)
	failed_panel["batches"][0]["tasks"][0]["status"] = "failed"
	main._on_state({"workers": staff, "bot_panel": failed_panel})
	check("真任务失败触发一次甩锅", lines.size() == 1, str(lines))
	check("甩锅文案带上任务标题", lines.size() == 1 and String(lines[0]).contains("实现登录接口"))
	check("甩锅文案不再承诺心情 -6", lines.size() == 1 and not String(lines[0]).contains("心情"))
	# 同一个失败任务刷新：不重复甩。
	main._on_state({"workers": staff, "bot_panel": failed_panel})
	check("同一个失败任务不重复甩锅", lines.size() == 1, str(lines))
	# 失败 → 恢复 → 再失败：同一单一辈子只甩一次。
	var back: Dictionary = failed_panel.duplicate(true)
	back["batches"][0]["tasks"][0]["status"] = "running"
	main._on_state({"workers": staff, "bot_panel": back})
	var again: Dictionary = failed_panel.duplicate(true)
	again["batches"][0]["tasks"][0]["status"] = "failed"
	main._on_state({"workers": staff, "bot_panel": again})
	check("同一个任务只甩一次（失败→恢复→再失败也不重复）", lines.size() == 1, str(lines))
	# 冷却期内第二个任务失败：不排队、不追加播报。
	var second: Dictionary = failed_panel.duplicate(true)
	second["batches"][0]["tasks"].append(
		{"bot_id": "bot-flash", "title": "写完接口", "status": "failed"})
	main._on_state({"workers": staff, "bot_panel": second})
	check("冷却期内第二个失败不追加播报", lines.size() == 1, str(lines))
	# 复盘会面板：背锅那一行也不再说「心情 -6」。
	main.blame_ui.show_meeting({"kind": "blame", "phase": "settled",
		"settled": {"culprit": "m3"}})
	await process_frame
	var settled := String(main.blame_ui._settled_text().get("msg", ""))
	check("复盘会背锅文案不再报心情 -6",
		settled.contains("背锅") and not settled.contains("心情"), settled)
	main.blame_ui.hide_meeting()
	check("会议结束后复盘会面板隐藏", not main.blame_ui.visible)
	main.queue_free()
	await process_frame
	print("BLAME INPUT: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)
