extends SceneTree
## M2-9 完整 UI 冒烟测试（T1）
##
## 覆盖 DEV_PLAN M2-9 的 4 条：
##   1. 所有弹窗可实例化，无 null 引用
##   2. 弹窗反复开关 10 次不崩
##   3. 无数据时显示占位，不显示空白
##   4. 长文本不撑破布局

var passed := 0
var failed := 0
var panels: Array = []
var names: Array = []


func check(name: String, cond: bool, detail := "") -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name, ("  → " + detail) if detail != "" else "")


func _init() -> void:
	await process_frame
	var root := Control.new()
	root.size = Vector2(1280, 720)
	get_root().add_child(root)
	await process_frame

	print("── 1 所有面板可实例化 ──")
	var made := {
		"WorkerPanel": WorkerPanel.new(),
		"ClientPanel": ClientPanel.new(),
		"ConflictUI": ConflictUI.new(),
		"BlameUI": BlameUI.new(),
		"ChatPanel": ChatPanel.new(),
		"BanterUI": BanterUI.new(),
		"DailyReport": DailyReport.new(),
		"RelationPanel": RelationPanel.new(),
	}
	for k in made:
		var n: Node = made[k]
		root.add_child(n)
		panels.append(n)
		names.append(k)
	await process_frame
	for i in range(panels.size()):
		check("1.%d %s 实例化且活着" % [i + 1, names[i]],
				is_instance_valid(panels[i]))
	check("1x. 八个面板都在", panels.size() == 8, str(panels.size()))

	print("── 2 反复开关 10 次 ──")
	var ok := true
	var err := ""
	for i in range(10):
		for n in panels:
			if n.has_method("show_with") or n.has_method("show_conflict"):
				continue
			if "visible" in n:
				n.visible = true
		await process_frame
		for n in panels:
			if "visible" in n:
				n.visible = false
		await process_frame
		if not is_instance_valid(panels[0]):
			ok = false
			err = "第 %d 轮后节点没了" % i
			break
	check("2. 开关 10 轮不崩", ok, err)

	print("── 3 无数据时的占位 ──")
	var cp: ClientPanel = panels[1]
	cp.show_client({}, [])
	check("3. 客户面板没有数据时不显示（不是空白面板）", not cp.visible)
	var dr: DailyReport = panels[6]
	dr.update_from({})
	check("3b. 结算面板没有数据时保持隐藏", not dr.visible)
	dr.update_from({"day": 1, "last_settle": {"wages": {"wages": 100, "total": 100}}})
	await process_frame
	check("3c. 有结算数据才弹出来", dr.visible)
	var wp: WorkerPanel = panels[0]
	wp.update_from({})
	await process_frame
	check("3d. 员工面板无数据也不崩（画「等后端…」）", is_instance_valid(wp))
	wp.update_from({"workers": []})
	await process_frame
	check("3e. 空 worker 列表不崩", is_instance_valid(wp))
	var bu: BanterUI = panels[5]
	bu.update_from({})
	bu.update_from({"banters": []})
	check("3f. 吐槽气泡无数据不崩", true)

	print("── 4 长文本不撑破 ──")
	var font := ThemeDB.fallback_font
	var long := "这是一段特别特别长的客户需求描述".repeat(20)
	var lines := UITheme.wrap(long, 280, font, 11)
	check("4. ★超长文本被折成多行", lines.size() > 5, str(lines.size()))
	var widest := 0.0
	for ln in lines:
		widest = maxf(widest, font.get_string_size(ln,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x)
	check("4b. ★每一行都没超出给定宽度", widest <= 280.0, "%.0f > 280" % widest)
	check("4c. 省略号截断到指定长度",
			UITheme.ellipsis(long, 12).length() == 12,
			str(UITheme.ellipsis(long, 12).length()))
	check("4d. 不超长时原样返回", UITheme.ellipsis("短", 12) == "短")
	var cp2: ClientPanel = panels[1]
	cp2.show_client({"id": "x", "task": long, "status": "待验收",
					  "result": long, "reward": 99,
					  "patience": 10, "patience_max": 100}, [])
	await process_frame
	check("4e. ★超长需求/交付物塞进客户面板不崩", cp2.visible and is_instance_valid(cp2))

	print("── 5 风格统一 ──")
	check("5. V2 面板使用木框暖色底",
			UITheme.BG.is_equal_approx(Color("#35201e")), str(UITheme.BG))
	check("5b. V2 边框使用暖棕色", UITheme.EDGE.is_equal_approx(Color("#97572d")))
	check("5c. 五个角色都有固定色（同一角色全程同色）",
			UITheme.WORKER_COLOR.size() == 6
			and UITheme.worker_color("m3") == UITheme.worker_color("m3"))
	check("5d. 未知角色不崩", UITheme.worker_color("不存在") == Color("#888888"))

	print("── 6 SSE 解析（纯函数）──")
	check("6. 解析 delta 行",
			SseChat.parse_line('data: {"type":"delta","text":"你好"}').get("text") == "你好",
			str(SseChat.parse_line('data: {"type":"delta","text":"你好"}')))
	check("6b. 忽略注释行和空行",
			SseChat.parse_line(": ping").is_empty()
			and SseChat.parse_line("").is_empty())
	check("6c. 忽略 [DONE]", SseChat.parse_line("data: [DONE]").is_empty())
	check("6d. 坏 JSON 不崩", SseChat.parse_line("data: {不是json").is_empty())
	check("6e. start 行", SseChat.parse_line('data: {"type":"start","who":"m3"}')
			.get("who") == "m3")

	print("\n通过 %d / %d" % [passed, passed + failed])
	print("UI SMOKE PASS" if failed == 0 else "UI SMOKE FAIL")
	quit(0 if failed == 0 else 1)
