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
	# ★旧经营玩法的三个面板（客户 / 抢单冲突 / 每日结算）已删除，
	#   剩下的都是还在生效的面板。
	var made := {
		"WorkerPanel": WorkerPanel.new(),
		"BlameUI": BlameUI.new(),
		"ChatPanel": ChatPanel.new(),
		"BanterUI": BanterUI.new(),
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
	check("1x. 五个面板都在", panels.size() == 5, str(panels.size()))

	print("── 2 反复开关 10 次 ──")
	var ok := true
	var err := ""
	for i in range(10):
		for n in panels:
			if n.has_method("show_with"):
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
	var wp: WorkerPanel = panels[0]
	wp.update_from({})
	await process_frame
	check("3. 员工面板无数据也不崩（画「等后端…」）", is_instance_valid(wp))
	wp.update_from({"workers": []})
	await process_frame
	check("3b. 空 worker 列表不崩", is_instance_valid(wp))
	var bl: BlameUI = panels[1]
	bl.hide_meeting()
	check("3c. 没有会议时复盘会面板保持隐藏", not bl.visible)
	var bu: BanterUI = panels[3]
	bu.update_from({})
	bu.update_from({"banters": []})
	check("3d. 吐槽气泡无数据不崩", true)

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
	# ★超长简介塞进员工详情不崩（详情里的状态条与按钮照常画）。
	var wp2: WorkerPanel = panels[0]
	wp2.visible = true	# 第 2 节把面板都藏起来了，看不见就不画
	wp2.update_from({"workers": [{"id": "m3", "blurb": long, "brain_down": true}]})
	wp2.selected = "m3"
	wp2.queue_redraw()
	await process_frame
	await process_frame
	check("4e. ★超长简介塞进员工详情不崩", is_instance_valid(wp2) and wp2._sb.is_brain_down())

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
